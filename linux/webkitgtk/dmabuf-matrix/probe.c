#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

#include <cairo.h>
#include <glib-unix.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum {
  EXIT_CONFIG = 64,
  EXIT_DISPLAY = 69,
  EXIT_ORACLE = 70,
  EXIT_TIMEOUT = 124,
  VIEW_WIDTH = 320,
  VIEW_HEIGHT = 240,
};

typedef enum {
  STYLE_OPAQUE,
  STYLE_TRANSPARENT,
} Style;

typedef struct {
  GtkWidget *window;
  GtkWidget *backdrop;
  WebKitWebView *web_view;
  const char *output_path;
  const char *nonce;
  Style style;
  gboolean fault_black_compositor;
  gboolean terminal;
  guint timeout_source;
  guint release_source;
  int result;
} Probe;

static void finish_probe(Probe *probe, int result) {
  if (probe->terminal) {
    return;
  }
  probe->terminal = TRUE;
  probe->result = result;
  gtk_main_quit();
}

static gboolean release_probe(int fd, GIOCondition condition, void *data) {
  Probe *probe = data;
  probe->release_source = 0;
  unsigned char byte = 0;
  const ssize_t count = read(fd, &byte, 1);
  if ((condition & (G_IO_ERR | G_IO_NVAL)) != 0 || count != 1 || byte != 'R') {
    g_printerr("KEL171-RELEASE-CHANNEL\n");
    finish_probe(probe, EXIT_ORACLE);
  } else {
    finish_probe(probe, EXIT_SUCCESS);
  }
  return G_SOURCE_REMOVE;
}

static gboolean draw_probe_window(GtkWidget *widget, cairo_t *context, void *data) {
  (void)widget;
  (void)data;
  cairo_set_operator(context, CAIRO_OPERATOR_SOURCE);
  cairo_set_source_rgba(context, 0, 0, 0, 0);
  cairo_paint(context);
  cairo_set_operator(context, CAIRO_OPERATOR_OVER);
  return FALSE;
}

static gboolean draw_backdrop(GtkWidget *widget, cairo_t *context, void *data) {
  (void)widget;
  (void)data;
  cairo_set_operator(context, CAIRO_OPERATOR_SOURCE);
  cairo_set_source_rgb(context, 0, 204.0 / 255.0, 68.0 / 255.0);
  cairo_paint(context);
  cairo_set_operator(context, CAIRO_OPERATOR_OVER);
  return FALSE;
}

static const char *style_name(Style style) {
  return style == STYLE_OPAQUE ? "opaque" : "transparent";
}

static gboolean is_lower_hex_nonce(const char *value) {
  if (value == NULL || strlen(value) != 32) {
    return FALSE;
  }
  for (size_t index = 0; index < 32; index += 1) {
    const char byte = value[index];
    if (!((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f'))) {
      return FALSE;
    }
  }
  return TRUE;
}

static void print_json_string(const char *value) {
  putchar('"');
  for (const unsigned char *cursor = (const unsigned char *)value; *cursor != '\0';
       cursor += 1) {
    switch (*cursor) {
      case '\\':
        fputs("\\\\", stdout);
        break;
      case '"':
        fputs("\\\"", stdout);
        break;
      case '\n':
        fputs("\\n", stdout);
        break;
      case '\r':
        fputs("\\r", stdout);
        break;
      case '\t':
        fputs("\\t", stdout);
        break;
      default:
        if (*cursor < 0x20) {
          fprintf(stdout, "\\u%04x", (unsigned int)*cursor);
        } else {
          putchar((int)*cursor);
        }
    }
  }
  putchar('"');
}

static uint32_t surface_pixel(cairo_surface_t *surface, int x, int y) {
  const unsigned char *data = cairo_image_surface_get_data(surface);
  const int stride = cairo_image_surface_get_stride(surface);
  uint32_t pixel = 0;
  memcpy(&pixel, data + (y * stride) + (x * 4), sizeof(pixel));
  return pixel;
}

static gboolean timeout_probe(void *data) {
  Probe *probe = data;
  probe->timeout_source = 0;
  g_printerr("KEL171-TIMEOUT\n");
  finish_probe(probe, EXIT_TIMEOUT);
  return G_SOURCE_REMOVE;
}

static void snapshot_ready(GObject *source, GAsyncResult *result, void *data) {
  Probe *probe = data;
  GError *error = NULL;
  cairo_surface_t *surface =
      webkit_web_view_get_snapshot_finish(WEBKIT_WEB_VIEW(source), result, &error);
  if (surface == NULL) {
    g_printerr("KEL171-SNAPSHOT: %s\n", error != NULL ? error->message : "unknown error");
    g_clear_error(&error);
    finish_probe(probe, EXIT_ORACLE);
    return;
  }
  if (probe->terminal) {
    cairo_surface_destroy(surface);
    return;
  }

  cairo_surface_flush(surface);
  const cairo_surface_type_t type = cairo_surface_get_type(surface);
  const cairo_format_t format = type == CAIRO_SURFACE_TYPE_IMAGE
                                    ? cairo_image_surface_get_format(surface)
                                    : CAIRO_FORMAT_INVALID;
  const int width = type == CAIRO_SURFACE_TYPE_IMAGE
                        ? cairo_image_surface_get_width(surface)
                        : 0;
  const int height = type == CAIRO_SURFACE_TYPE_IMAGE
                         ? cairo_image_surface_get_height(surface)
                         : 0;
  uint32_t marker = 0;
  uint32_t background = 0;
  if (type == CAIRO_SURFACE_TYPE_IMAGE && format == CAIRO_FORMAT_ARGB32 &&
      width >= VIEW_WIDTH && height >= VIEW_HEIGHT) {
    marker = surface_pixel(surface, 16, 16);
    background = surface_pixel(surface, 200, 120);
  }

  const uint32_t expected_marker = UINT32_C(0xffff00aa);
  const uint32_t expected_background =
      probe->style == STYLE_OPAQUE ? UINT32_C(0xff203040) : UINT32_C(0x00000000);
  const gboolean oracle_pass = type == CAIRO_SURFACE_TYPE_IMAGE &&
                               format == CAIRO_FORMAT_ARGB32 && width >= VIEW_WIDTH &&
                               height >= VIEW_HEIGHT && marker == expected_marker &&
                               background == expected_background;

  cairo_status_t png_status = cairo_surface_write_to_png(surface, probe->output_path);
  GdkDisplay *display = gdk_display_get_default();
  const char *disable_dmabuf = g_getenv("WEBKIT_DISABLE_DMABUF_RENDERER");
  printf("{\"schema_version\":1,\"nonce\":");
  print_json_string(probe->nonce);
  printf(",\"style\":");
  print_json_string(style_name(probe->style));
  printf(",\"gdk_display_type\":");
  print_json_string(display != NULL ? G_OBJECT_TYPE_NAME(display) : "");
  printf(",\"gdk_display_name\":");
  print_json_string(display != NULL ? gdk_display_get_name(display) : "");
  printf(",\"gtk_runtime\":\"%u.%u.%u\",\"gtk_headers\":\"%u.%u.%u\"",
         gtk_get_major_version(), gtk_get_minor_version(), gtk_get_micro_version(),
         GTK_MAJOR_VERSION, GTK_MINOR_VERSION, GTK_MICRO_VERSION);
  printf(",\"webkit_runtime\":\"%u.%u.%u\",\"webkit_headers\":\"%u.%u.%u\"",
         webkit_get_major_version(), webkit_get_minor_version(), webkit_get_micro_version(),
         WEBKIT_MAJOR_VERSION, WEBKIT_MINOR_VERSION, WEBKIT_MICRO_VERSION);
  printf(",\"disable_dmabuf_renderer\":");
  if (disable_dmabuf == NULL) {
    fputs("null", stdout);
  } else {
    print_json_string(disable_dmabuf);
  }
  printf(",\"fault_black_compositor\":%s",
         probe->fault_black_compositor ? "true" : "false");
  printf(",\"surface\":{\"type\":%d,\"format\":%d,\"width\":%d,\"height\":%d,"
         "\"marker_argb\":\"%08x\",\"background_argb\":\"%08x\"},"
         "\"oracle_pass\":%s,\"png_status\":%d}\n",
         (int)type, (int)format, width, height, marker, background,
         oracle_pass ? "true" : "false", (int)png_status);
  fflush(stdout);

  if (png_status != CAIRO_STATUS_SUCCESS) {
    g_printerr("KEL171-PNG: %s\n", cairo_status_to_string(png_status));
    finish_probe(probe, EXIT_ORACLE);
  } else if (!oracle_pass) {
    g_printerr("KEL171-PIXEL-ORACLE expected-marker=%08x expected-background=%08x\n",
               expected_marker, expected_background);
    finish_probe(probe, EXIT_ORACLE);
  } else {
    if (probe->timeout_source != 0) {
      g_source_remove(probe->timeout_source);
      probe->timeout_source = 0;
    }
    probe->timeout_source = g_timeout_add_seconds(200, timeout_probe, probe);
    probe->release_source = g_unix_fd_add(
        STDIN_FILENO, G_IO_IN | G_IO_HUP | G_IO_ERR | G_IO_NVAL, release_probe,
        probe);
  }
  cairo_surface_destroy(surface);
}

static void title_changed(WebKitWebView *web_view, GParamSpec *parameter, void *data) {
  (void)parameter;
  Probe *probe = data;
  if (probe->terminal || probe->release_source != 0) {
    return;
  }
  const char *title = webkit_web_view_get_title(web_view);
  char *expected = g_strdup_printf("KEL171-READY:%s", probe->nonce);
  const gboolean ready = title != NULL && strcmp(title, expected) == 0;
  g_free(expected);
  if (!ready) {
    return;
  }

  webkit_web_view_get_snapshot(
      web_view, WEBKIT_SNAPSHOT_REGION_VISIBLE,
      WEBKIT_SNAPSHOT_OPTIONS_TRANSPARENT_BACKGROUND, NULL, snapshot_ready, probe);
}

static gboolean parse_arguments(int argc, char **argv, Probe *probe) {
  if (argc != 5 || strcmp(argv[1], "--style") != 0 ||
      strcmp(argv[3], "--output") != 0) {
    return FALSE;
  }
  if (strcmp(argv[2], "opaque") == 0) {
    probe->style = STYLE_OPAQUE;
  } else if (strcmp(argv[2], "transparent") == 0) {
    probe->style = STYLE_TRANSPARENT;
  } else {
    return FALSE;
  }
  probe->output_path = argv[4];
  probe->nonce = g_getenv("KEL171_NONCE");
  probe->fault_black_compositor =
      g_strcmp0(g_getenv("KEL171_FAULT_BLACK_COMPOSITOR"), "1") == 0;
  return is_lower_hex_nonce(probe->nonce);
}

int main(int argc, char **argv) {
  Probe probe = {.result = EXIT_ORACLE};
  if (!parse_arguments(argc, argv, &probe)) {
    g_printerr("usage: KEL171_NONCE=<32-ascii> %s --style opaque|transparent --output FILE\n",
               argv[0]);
    return EXIT_CONFIG;
  }
  if (!gtk_init_check(NULL, NULL)) {
    g_printerr("KEL171-DISPLAY-UNAVAILABLE\n");
    return EXIT_DISPLAY;
  }

  if (probe.style == STYLE_TRANSPARENT) {
    probe.backdrop = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    GtkWidget *backdrop_content = gtk_drawing_area_new();
    gtk_widget_set_size_request(backdrop_content, VIEW_WIDTH + 100, VIEW_HEIGHT + 100);
    gtk_container_add(GTK_CONTAINER(probe.backdrop), backdrop_content);
    gtk_window_set_default_size(GTK_WINDOW(probe.backdrop), VIEW_WIDTH + 100,
                                VIEW_HEIGHT + 100);
    gtk_window_set_resizable(GTK_WINDOW(probe.backdrop), FALSE);
    gtk_window_set_decorated(GTK_WINDOW(probe.backdrop), FALSE);
    g_signal_connect(backdrop_content, "draw", G_CALLBACK(draw_backdrop), NULL);
    gtk_widget_show_all(probe.backdrop);
  }

  probe.window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  probe.web_view = WEBKIT_WEB_VIEW(webkit_web_view_new());
  gtk_window_set_title(GTK_WINDOW(probe.window), probe.nonce);
  gtk_window_set_default_size(GTK_WINDOW(probe.window), VIEW_WIDTH, VIEW_HEIGHT);
  gtk_window_set_resizable(GTK_WINDOW(probe.window), FALSE);
  gtk_window_set_decorated(GTK_WINDOW(probe.window), FALSE);
  if (probe.backdrop != NULL) {
    gtk_window_set_transient_for(GTK_WINDOW(probe.window), GTK_WINDOW(probe.backdrop));
    gtk_window_set_destroy_with_parent(GTK_WINDOW(probe.window), TRUE);
  }
  gtk_container_add(GTK_CONTAINER(probe.window), GTK_WIDGET(probe.web_view));
  GdkRGBA web_view_background = probe.style == STYLE_OPAQUE
                                    ? (GdkRGBA){.red = 32.0 / 255.0,
                                                .green = 48.0 / 255.0,
                                                .blue = 64.0 / 255.0,
                                                .alpha = 1.0}
                                : (probe.fault_black_compositor
                                       ? (GdkRGBA){.red = 0,
                                                   .green = 0,
                                                   .blue = 0,
                                                   .alpha = 1}
                                       : (GdkRGBA){.red = 0,
                                                   .green = 0,
                                                   .blue = 0,
                                                   .alpha = 0});
  webkit_web_view_set_background_color(probe.web_view, &web_view_background);
  if (probe.style == STYLE_TRANSPARENT) {
    gtk_widget_set_app_paintable(probe.window, TRUE);
    GdkScreen *screen = gtk_widget_get_screen(probe.window);
    GdkVisual *visual = gdk_screen_get_rgba_visual(screen);
    if (visual != NULL) {
      gtk_widget_set_visual(probe.window, visual);
    }
    g_signal_connect(probe.window, "draw", G_CALLBACK(draw_probe_window), NULL);
  }

  g_signal_connect(probe.web_view, "notify::title", G_CALLBACK(title_changed), &probe);
  gtk_widget_show_all(probe.window);
  gtk_window_present(GTK_WINDOW(probe.window));
  if (g_strcmp0(g_getenv("KEL171_TEST_AUDIT"), "1") == 0) {
    webkit_web_view_load_uri(probe.web_view, "https://keld.invalid/audit");
  }

  const char *background = probe.style == STYLE_OPAQUE ? "#203040" : "transparent";
  const gboolean suppress_ready =
      g_strcmp0(g_getenv("KEL171_TEST_SUPPRESS_READY"), "1") == 0;
  char *html = g_strdup_printf(
      "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'>"
      "<style>html,body{margin:0;width:100%%;height:100%%;background:%s;overflow:hidden}"
      "#marker{width:64px;height:64px;background:#ff00aa}</style><div id=marker></div>"
      "<script>%srequestAnimationFrame(()=>requestAnimationFrame(()=>document.title="
      "'KEL171-READY:%s'))</script>",
      background, suppress_ready ? "false&&" : "", probe.nonce);
  webkit_web_view_load_html(probe.web_view, html, "https://keld.invalid/");
  g_free(html);
  guint timeout_milliseconds = 15 * 1000;
  if (suppress_ready && g_strcmp0(g_getenv("KEL171_TEST_SHORT_TIMEOUT"), "1") == 0) {
    timeout_milliseconds = 50;
  }
  probe.timeout_source = g_timeout_add(timeout_milliseconds, timeout_probe, &probe);
  gtk_main();
  if (probe.timeout_source != 0) {
    g_source_remove(probe.timeout_source);
  }
  if (probe.release_source != 0) {
    g_source_remove(probe.release_source);
  }
  gtk_widget_destroy(probe.window);
  if (probe.backdrop != NULL) {
    gtk_widget_destroy(probe.backdrop);
  }
  while (g_main_context_iteration(NULL, FALSE)) {
  }
  return probe.result;
}
