# Ghostty Embedding API Reference

> Source: `vendor/ghostty/include/ghostty.h` (Ghostty v1.3.0, commit `703d11c642a96af9e54b55b04f131bf3888948a9`)
> Header is the verbatim contract — do not fabricate signatures.

This document records the C embedding API that Tasks 6–7 bind against. All
signatures are copied verbatim from `ghostty.h` unless noted.

---

## Opaque Handle Types

```c
typedef void* ghostty_app_t;
typedef void* ghostty_config_t;
typedef void* ghostty_surface_t;
typedef void* ghostty_inspector_t;
```

---

## Runtime / App Init

### Library bootstrap

```c
int ghostty_init(uintptr_t, char**);
```

Called once at process start (argc, argv). Returns 0 on success.

```c
ghostty_info_s ghostty_info(void);
```

Returns build mode and version string.

```c
void ghostty_cli_try_action(void);
```

Attempts to execute a CLI action from argv (e.g. `+list-fonts`). Returns if
no CLI action is present.

### App lifecycle

```c
ghostty_app_t ghostty_app_new(const ghostty_runtime_config_s*, ghostty_config_t);
void ghostty_app_free(ghostty_app_t);
void ghostty_app_tick(ghostty_app_t);
void* ghostty_app_userdata(ghostty_app_t);
```

`ghostty_app_tick` must be called on the UI thread in response to the
`wakeup_cb` callback (see Runtime Callback Table below).

---

## Configuration

```c
ghostty_config_t ghostty_config_new();
void ghostty_config_free(ghostty_config_t);
ghostty_config_t ghostty_config_clone(ghostty_config_t);
void ghostty_config_load_cli_args(ghostty_config_t);
void ghostty_config_load_file(ghostty_config_t, const char*);
void ghostty_config_load_default_files(ghostty_config_t);
void ghostty_config_load_recursive_files(ghostty_config_t);
void ghostty_config_finalize(ghostty_config_t);
bool ghostty_config_get(ghostty_config_t, void*, const char*, uintptr_t);
ghostty_input_trigger_s ghostty_config_trigger(ghostty_config_t, const char*, uintptr_t);
uint32_t ghostty_config_diagnostics_count(ghostty_config_t);
ghostty_diagnostic_s ghostty_config_get_diagnostic(ghostty_config_t, uint32_t);
ghostty_string_s ghostty_config_open_path(void);
```

Call `ghostty_config_finalize` before passing the config to `ghostty_app_new`.

---

## Surface Creation and Render Target

A *surface* is a single terminal pane backed by a Metal layer.

### Config

```c
ghostty_surface_config_s ghostty_surface_config_new();
```

The config struct:

```c
typedef struct {
  ghostty_platform_e platform_tag;   // GHOSTTY_PLATFORM_MACOS or GHOSTTY_PLATFORM_IOS
  ghostty_platform_u platform;       // union: macos.nsview (void*) or ios.uiview (void*)
  void* userdata;
  double scale_factor;
  float font_size;
  const char* working_directory;
  const char* command;
  ghostty_env_var_s* env_vars;
  size_t env_var_count;
  const char* initial_input;
  bool wait_after_command;
  ghostty_surface_context_e context;  // WINDOW / TAB / SPLIT
} ghostty_surface_config_s;
```

**Render target:** The embedder passes an `NSView*` (macOS) or `UIView*` (iOS)
as `platform.macos.nsview` / `platform.ios.uiview`. Ghostty's renderer creates
and manages a `CAMetalLayer` on top of that view — the embedder does NOT own the
Metal layer. On iOS the UIView subclass must return `CAMetalLayer.self` from
`layerClass`.

### Lifecycle

```c
ghostty_surface_t ghostty_surface_new(ghostty_app_t, const ghostty_surface_config_s*);
void ghostty_surface_free(ghostty_surface_t);
void* ghostty_surface_userdata(ghostty_surface_t);
ghostty_app_t ghostty_surface_app(ghostty_surface_t);
```

### Draw / Tick

```c
void ghostty_surface_draw(ghostty_surface_t);
void ghostty_surface_refresh(ghostty_surface_t);
```

`ghostty_surface_draw` performs a Metal render pass. Must be called from the
main (UI) thread. `ghostty_surface_refresh` marks the surface dirty so the next
`draw` includes new terminal output.

### Size and Focus

```c
void ghostty_surface_set_size(ghostty_surface_t, uint32_t width_px, uint32_t height_px);
ghostty_surface_size_s ghostty_surface_size(ghostty_surface_t);
void ghostty_surface_set_content_scale(ghostty_surface_t, double x, double y);
void ghostty_surface_set_focus(ghostty_surface_t, bool focused);
void ghostty_surface_set_occlusion(ghostty_surface_t, bool occluded);
void ghostty_surface_set_color_scheme(ghostty_surface_t, ghostty_color_scheme_e);
```

The size struct:

```c
typedef struct {
  uint16_t columns;
  uint16_t rows;
  uint32_t width_px;
  uint32_t height_px;
  uint32_t cell_width_px;
  uint32_t cell_height_px;
} ghostty_surface_size_s;
```

### Keyboard Input

```c
bool ghostty_surface_key(ghostty_surface_t, ghostty_input_key_s);
bool ghostty_surface_key_is_binding(ghostty_surface_t,
                                    ghostty_input_key_s,
                                    ghostty_binding_flags_e*);
ghostty_input_mods_e ghostty_surface_key_translation_mods(ghostty_surface_t,
                                                          ghostty_input_mods_e);
void ghostty_surface_text(ghostty_surface_t, const char* utf8, uintptr_t len);
void ghostty_surface_preedit(ghostty_surface_t, const char* utf8, uintptr_t len);
```

Key event struct:

```c
typedef struct {
  ghostty_input_action_e action;     // PRESS / RELEASE / REPEAT
  ghostty_input_mods_e mods;
  ghostty_input_mods_e consumed_mods;
  uint32_t keycode;
  const char* text;
  uint32_t unshifted_codepoint;
  bool composing;
} ghostty_input_key_s;
```

### Mouse Input

```c
bool ghostty_surface_mouse_captured(ghostty_surface_t);
bool ghostty_surface_mouse_button(ghostty_surface_t,
                                  ghostty_input_mouse_state_e,
                                  ghostty_input_mouse_button_e,
                                  ghostty_input_mods_e);
void ghostty_surface_mouse_pos(ghostty_surface_t,
                               double x,
                               double y,
                               ghostty_input_mods_e);
void ghostty_surface_mouse_scroll(ghostty_surface_t,
                                  double dx,
                                  double dy,
                                  ghostty_input_scroll_mods_t);
void ghostty_surface_mouse_pressure(ghostty_surface_t, uint32_t stage, double pressure);
```

### IME

```c
void ghostty_surface_ime_point(ghostty_surface_t,
                               double* x, double* y,
                               double* w, double* h);
```

---

## Embedder Callback Table (`ghostty_runtime_config_s`)

All callbacks are invoked from Ghostty's internal threads — the embedder must
dispatch to the UI thread as needed.

```c
typedef void (*ghostty_runtime_wakeup_cb)(void* userdata);
typedef void (*ghostty_runtime_read_clipboard_cb)(void* userdata,
                                                  ghostty_clipboard_e clipboard,
                                                  void* state);
typedef void (*ghostty_runtime_confirm_read_clipboard_cb)(void* userdata,
                                                          const char* text,
                                                          void* state,
                                                          ghostty_clipboard_request_e kind);
typedef void (*ghostty_runtime_write_clipboard_cb)(void* userdata,
                                                   ghostty_clipboard_e clipboard,
                                                   const ghostty_clipboard_content_s* content,
                                                   size_t len,
                                                   bool confirm);
typedef void (*ghostty_runtime_close_surface_cb)(void* userdata, bool process_alive);
typedef bool (*ghostty_runtime_action_cb)(ghostty_app_t,
                                          ghostty_target_s target,
                                          ghostty_action_s action);
```

The runtime config struct that embeds these:

```c
typedef struct {
  void* userdata;
  bool supports_selection_clipboard;
  ghostty_runtime_wakeup_cb wakeup_cb;
  ghostty_runtime_action_cb action_cb;
  ghostty_runtime_read_clipboard_cb read_clipboard_cb;
  ghostty_runtime_confirm_read_clipboard_cb confirm_read_clipboard_cb;
  ghostty_runtime_write_clipboard_cb write_clipboard_cb;
  ghostty_runtime_close_surface_cb close_surface_cb;
} ghostty_runtime_config_s;
```

### Callback responsibilities

| Callback | Purpose |
|---|---|
| `wakeup_cb` | Ghostty needs `ghostty_app_tick` to be called on the main thread (schedule via `DispatchQueue.main.async`). |
| `action_cb` | Ghostty wants the host app to handle an action (set title, open new window, ring bell, clipboard, child exit, etc.). Returns `true` if handled. |
| `read_clipboard_cb` | Ghostty requests clipboard contents; embedder calls `ghostty_surface_complete_clipboard_request` with the data. |
| `confirm_read_clipboard_cb` | Ghostty requests the user confirm a clipboard read (OSC 52); embedder shows UI then calls `ghostty_surface_complete_clipboard_request`. |
| `write_clipboard_cb` | Ghostty wants to write `content` to `clipboard`. |
| `close_surface_cb` | Surface's child process exited (`process_alive=false`) or explicitly closed; embedder should destroy the surface view. |

---

## Action Dispatch (`ghostty_action_s`)

`action_cb` delivers typed actions via:

```c
typedef struct {
  ghostty_action_tag_e tag;
  ghostty_action_u action;
} ghostty_action_s;
```

Key action tags for Zetty (Tasks 6–7):

| Tag | Payload type | Meaning |
|---|---|---|
| `GHOSTTY_ACTION_SET_TITLE` | `ghostty_action_set_title_s { const char* title }` | Update window/tab title |
| `GHOSTTY_ACTION_RING_BELL` | — | Terminal bell |
| `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` | `ghostty_action_desktop_notification_s { title, body }` | OS notification |
| `GHOSTTY_ACTION_SHOW_CHILD_EXITED` | — | Child process exited |
| `GHOSTTY_ACTION_NEW_SPLIT` | `ghostty_action_split_direction_e` | User requested a split |
| `GHOSTTY_ACTION_CLOSE_TAB` | — | Close current tab |
| `GHOSTTY_ACTION_NEW_WINDOW` | — | Open new window |
| `GHOSTTY_ACTION_RELOAD_CONFIG` | `ghostty_action_reload_config_s { bool soft }` | Config reload |
| `GHOSTTY_ACTION_CONFIG_CHANGE` | `ghostty_action_config_change_s { ghostty_config_t config }` | New config object (caller frees) |
| `GHOSTTY_ACTION_PWD` | `ghostty_action_pwd_s { const char* pwd }` | Working dir changed |
| `GHOSTTY_ACTION_MOUSE_SHAPE` | `ghostty_action_mouse_shape_e` | Change cursor shape |
| `GHOSTTY_ACTION_SCROLLBAR` | `ghostty_action_scrollbar_s { total, offset, len }` | Scrollbar state update |

---

## Surface Clipboard Completion

```c
void ghostty_surface_complete_clipboard_request(ghostty_surface_t,
                                                const char* data,
                                                void* state,
                                                bool confirmed);
```

Called from the embedder after a `read_clipboard_cb` or
`confirm_read_clipboard_cb` to deliver (or deny) clipboard data back to Ghostty.

---

## Selection / Text Read

```c
bool ghostty_surface_has_selection(ghostty_surface_t);
bool ghostty_surface_read_selection(ghostty_surface_t, ghostty_text_s* out);
bool ghostty_surface_read_text(ghostty_surface_t,
                               ghostty_selection_s sel,
                               ghostty_text_s* out);
void ghostty_surface_free_text(ghostty_surface_t, ghostty_text_s*);
```

---

## Close / Split Controls

```c
void ghostty_surface_request_close(ghostty_surface_t);
void ghostty_surface_split(ghostty_surface_t, ghostty_action_split_direction_e);
void ghostty_surface_split_focus(ghostty_surface_t, ghostty_action_goto_split_e);
void ghostty_surface_split_resize(ghostty_surface_t,
                                  ghostty_action_resize_split_direction_e,
                                  uint16_t amount);
void ghostty_surface_split_equalize(ghostty_surface_t);
```

---

## App-Level Controls

```c
void ghostty_app_set_focus(ghostty_app_t, bool);
bool ghostty_app_key(ghostty_app_t, ghostty_input_key_s);
bool ghostty_app_key_is_binding(ghostty_app_t, ghostty_input_key_s);
void ghostty_app_keyboard_changed(ghostty_app_t);
void ghostty_app_open_config(ghostty_app_t);
void ghostty_app_update_config(ghostty_app_t, ghostty_config_t);
bool ghostty_app_needs_confirm_quit(ghostty_app_t);
bool ghostty_app_has_global_keybinds(ghostty_app_t);
void ghostty_app_set_color_scheme(ghostty_app_t, ghostty_color_scheme_e);
```

---

## macOS-only APIs

```c
#ifdef __APPLE__
// Surface
void ghostty_surface_set_display_id(ghostty_surface_t, uint32_t displayID);
void* ghostty_surface_quicklook_font(ghostty_surface_t);
bool ghostty_surface_quicklook_word(ghostty_surface_t, ghostty_text_s*);

// Inspector
bool ghostty_inspector_metal_init(ghostty_inspector_t, void* mtlDevice);
void ghostty_inspector_metal_render(ghostty_inspector_t, void* drawable, void* cmdBuffer);
bool ghostty_inspector_metal_shutdown(ghostty_inspector_t);
#endif
```

---

## Inspector

```c
ghostty_inspector_t ghostty_surface_inspector(ghostty_surface_t);
void ghostty_inspector_free(ghostty_surface_t);   // note: takes surface_t, not inspector_t
void ghostty_inspector_set_focus(ghostty_inspector_t, bool);
void ghostty_inspector_set_content_scale(ghostty_inspector_t, double, double);
void ghostty_inspector_set_size(ghostty_inspector_t, uint32_t, uint32_t);
void ghostty_inspector_mouse_button(ghostty_inspector_t,
                                    ghostty_input_mouse_state_e,
                                    ghostty_input_mouse_button_e,
                                    ghostty_input_mods_e);
void ghostty_inspector_mouse_pos(ghostty_inspector_t, double, double);
void ghostty_inspector_mouse_scroll(ghostty_inspector_t, double, double,
                                    ghostty_input_scroll_mods_t);
void ghostty_inspector_key(ghostty_inspector_t,
                           ghostty_input_action_e,
                           ghostty_input_key_e,
                           ghostty_input_mods_e);
void ghostty_inspector_text(ghostty_inspector_t, const char*);
```

---

## Threading Notes

- `ghostty_init`, `ghostty_app_new`, `ghostty_config_*` — call on **main thread** before any background work.
- `ghostty_app_tick` — **must** be dispatched to the **main thread** in response to `wakeup_cb`. The callback itself may arrive on any thread.
- `ghostty_surface_draw` — call on the **main thread** (Metal frame rendering).
- `ghostty_surface_key`, `ghostty_surface_mouse_*`, `ghostty_surface_text` — call on the **main thread**.
- `action_cb` — invoked on Ghostty's internal thread; dispatch UI work to main.
- `close_surface_cb` — invoked on Ghostty's internal thread; dispatch surface teardown to main.

---

## xcframework Build

```
zig build -Demit-xcframework -Doptimize=ReleaseFast --prefix zig-out
```

Output: `vendor/ghostty/macos/GhosttyKit.xcframework`

The xcframework bundles:
- macOS universal (arm64 + x86_64) static library
- iOS arm64 static library
- iOS Simulator arm64 static library

All slices include the `include/` header tree and dSYMs.
