#include <gtk/gtk.h>
#include <webkit/webkit.h>

#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

enum { CONFIG_ERROR = 64 };

typedef struct {
  WebKitWebView *web_view;
  char *url;
  gulong map_handler;
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
  g_free(state->url);
  g_free(state);
}

static gboolean decide_policy(WebKitWebView *web_view,
                              WebKitPolicyDecision *decision,
                              WebKitPolicyDecisionType decision_type,
                              void *data) {
  (void)web_view;
  const ViewState *state = data;
  const char *requested_url = NULL;
  if (decision_type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) {
    WebKitNavigationPolicyDecision *navigation_decision =
        WEBKIT_NAVIGATION_POLICY_DECISION(decision);
    WebKitNavigationAction *action =
        webkit_navigation_policy_decision_get_navigation_action(navigation_decision);
    WebKitURIRequest *request = webkit_navigation_action_get_request(action);
    requested_url = webkit_uri_request_get_uri(request);
  }
  if (decision_type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION &&
      requested_url != NULL && strcmp(requested_url, state->url) == 0) {
    webkit_policy_decision_use(decision);
    return TRUE;
  }
  if (decision_type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION ||
      decision_type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
    webkit_policy_decision_ignore(decision);
    g_printerr("KELD-BENCH-URL-BLOCKED\n");
    fflush(stderr);
    return TRUE;
  }
  return FALSE;
}

static void load_when_mapped(GtkWidget *window, void *data) {
  ViewState *state = data;
  g_signal_handler_disconnect(window, state->map_handler);
  state->map_handler = 0;
  gtk_widget_grab_focus(GTK_WIDGET(state->web_view));
  webkit_web_view_load_uri(state->web_view, state->url);
}

static void activate(GtkApplication *application, void *data) {
  const char *url = data;
  GtkWidget *window = gtk_application_window_new(application);
  GtkWidget *web_view = webkit_web_view_new();
  gtk_window_set_title(GTK_WINDOW(window), "GTK4 WebKitGTK native benchmark");
  gtk_window_set_default_size(GTK_WINDOW(window), 800, 500);
  gtk_window_set_child(GTK_WINDOW(window), web_view);

  ViewState *state = g_new0(ViewState, 1);
  state->web_view = WEBKIT_WEB_VIEW(web_view);
  state->url = g_strdup(url);
  g_object_set_data_full(G_OBJECT(window), "keld-bench-state", state, free_view_state);
  g_signal_connect(web_view, "decide-policy", G_CALLBACK(decide_policy), state);
  state->map_handler = g_signal_connect(window, "map", G_CALLBACK(load_when_mapped), state);
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
