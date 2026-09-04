#define _GNU_SOURCE

#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef void (*LoadUri)(WebKitWebView *, const gchar *);

static LoadUri resolve_load_uri(void) {
  void *symbol = dlsym(RTLD_NEXT, "webkit_web_view_load_uri");
  LoadUri function = NULL;
  if (sizeof(function) == sizeof(symbol)) {
    memcpy(&function, &symbol, sizeof(function));
  }
  return function;
}

void webkit_web_view_load_uri(WebKitWebView *web_view, const gchar *uri) {
  const char *receipt_path = g_getenv("KEL171_KELD_RECEIPT");
  if (receipt_path != NULL) {
    const int descriptor = open(receipt_path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (descriptor >= 0) {
      GdkDisplay *display = gtk_widget_get_display(GTK_WIDGET(web_view));
      const char *flag = g_getenv("WEBKIT_DISABLE_DMABUF_RENDERER");
      dprintf(descriptor,
              "schema_version=1\n"
              "pid=%ld\n"
              "uri=%s\n"
              "gdk_display_type=%s\n"
              "gdk_display_name=%s\n"
              "gtk_runtime=%u.%u.%u\n"
              "webkit_runtime=%u.%u.%u\n"
              "disable_dmabuf_renderer=%s\n",
              (long)getpid(), uri != NULL ? uri : "", display != NULL ? G_OBJECT_TYPE_NAME(display) : "",
              display != NULL ? gdk_display_get_name(display) : "", gtk_get_major_version(),
              gtk_get_minor_version(), gtk_get_micro_version(), webkit_get_major_version(),
              webkit_get_minor_version(), webkit_get_micro_version(),
              flag != NULL ? flag : "<absent>");
      close(descriptor);
    }
  }

  LoadUri original = resolve_load_uri();
  if (original != NULL) {
    original(web_view, uri);
  }
}
