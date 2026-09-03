#include <gtk/gtk.h>
#include <webkit/webkit.h>

#include <stdbool.h>
#include <stddef.h>
#include <string.h>

enum { CONFIG_ERROR = 64 };

typedef struct {
  GtkWindow *window;
  WebKitWebView *web_view;
  char *url;
} ViewState;

static bool is_lower_hex_nonce(const char *value, size_t length) {
  if (length != 32) {
    return false;
  }
  for (size_t index = 0; index < length; index += 1) {
    const char byte = value[index];
    if (!((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f'))) {
      return false;
    }
  }
  return true;
}

static bool is_benchmark_url(const char *value) {
  GError *error = NULL;
  GUri *uri = g_uri_parse(value, G_URI_FLAGS_NONE, &error);
  if (uri == NULL) {
    g_clear_error(&error);
    return false;
  }

  const char *scheme = g_uri_get_scheme(uri);
  const char *host = g_uri_get_host(uri);
  const char *path = g_uri_get_path(uri);
  const char *userinfo = g_uri_get_userinfo(uri);
  const char *query = g_uri_get_query(uri);
  const char *fragment = g_uri_get_fragment(uri);
  const int port = g_uri_get_port(uri);
  static const char prefix[] = "/run/";
  static const char suffix[] = "/index.html";

  bool valid = scheme != NULL && strcmp(scheme, "http") == 0 && host != NULL &&
               strcmp(host, "127.0.0.1") == 0 && port > 0 && port <= 65535 &&
               userinfo == NULL && query == NULL && fragment == NULL && path != NULL;
  if (valid) {
    const size_t path_length = strlen(path);
    const size_t prefix_length = sizeof(prefix) - 1;
    const size_t suffix_length = sizeof(suffix) - 1;
    valid = path_length == prefix_length + 32 + suffix_length &&
            memcmp(path, prefix, prefix_length) == 0 &&
            memcmp(path + prefix_length + 32, suffix, suffix_length) == 0 &&
            is_lower_hex_nonce(path + prefix_length, 32);
  }
  g_uri_unref(uri);
  return valid;
}

static void free_view_state(void *data) {
  ViewState *state = data;
  g_object_unref(state->web_view);
  g_object_unref(state->window);
  g_free(state->url);
  g_free(state);
}

static gboolean load_when_active(void *data) {
  ViewState *state = data;
  if (!gtk_window_is_active(state->window)) {
    return G_SOURCE_CONTINUE;
  }
  gtk_widget_grab_focus(GTK_WIDGET(state->web_view));
  webkit_web_view_load_uri(state->web_view, state->url);
  return G_SOURCE_REMOVE;
}

static void activate(GtkApplication *application, void *data) {
  const char *url = data;
  GtkWidget *window = gtk_application_window_new(application);
  GtkWidget *web_view = webkit_web_view_new();
  gtk_window_set_title(GTK_WINDOW(window), "GTK4 WebKitGTK native benchmark");
  gtk_window_set_default_size(GTK_WINDOW(window), 800, 500);
  gtk_window_set_child(GTK_WINDOW(window), web_view);

  ViewState *state = g_new0(ViewState, 1);
  state->window = g_object_ref(GTK_WINDOW(window));
  state->web_view = g_object_ref(WEBKIT_WEB_VIEW(web_view));
  state->url = g_strdup(url);
  g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, load_when_active, state, free_view_state);
  gtk_window_present(GTK_WINDOW(window));
}

int main(int argc, char **argv) {
  const char *url = g_getenv("KELD_BENCH_URL");
  if (url == NULL || !is_benchmark_url(url)) {
    g_printerr("KELD_BENCH_URL must be http://127.0.0.1:<port>/run/<32-lowercase-hex>/index.html\n");
    return CONFIG_ERROR;
  }

  GtkApplication *application =
      gtk_application_new("dev.keld.bench.gtk4", G_APPLICATION_NON_UNIQUE);
  g_signal_connect(application, "activate", G_CALLBACK(activate), (void *)url);
  const int status = g_application_run(G_APPLICATION(application), argc, argv);
  g_object_unref(application);
  return status;
}
