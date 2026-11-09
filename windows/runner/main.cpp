#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "app_links/app_links_plugin_c_api.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

BOOL CALLBACK FindRunnerWindow(HWND hwnd, LPARAM result) {
  wchar_t class_name[256];
  if (::GetClassNameW(hwnd, class_name, 256) == 0) {
    return TRUE;
  }
  if (::lstrcmpW(class_name, L"FLUTTER_RUNNER_WIN32_WINDOW") == 0) {
    *reinterpret_cast<HWND*>(result) = hwnd;
    return FALSE;
  }
  return TRUE;
}

// A second launch should bring the already running app back on screen instead
// of silently exiting while its window stays hidden in the tray.
void ActivateExistingWindow() {
  HWND existing = nullptr;
  ::EnumWindows(FindRunnerWindow, reinterpret_cast<LPARAM>(&existing));
  if (existing == nullptr) {
    return;
  }
  if (::IsIconic(existing)) {
    ::ShowWindow(existing, SW_RESTORE);
  } else {
    ::ShowWindow(existing, SW_SHOW);
  }
  // The Dart side may have faded the window before hiding it to the tray.
  if (::GetWindowLongPtr(existing, GWL_EXSTYLE) & WS_EX_LAYERED) {
    ::SetLayeredWindowAttributes(existing, 0, 255, LWA_ALPHA);
  }
  ::SetForegroundWindow(existing);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  ActivateExistingWindow();
  if (SendAppLinkToInstance()) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // https://github.com/flutter/flutter/issues/188635
  // https://github.com/flutter/flutter/issues/191050
  // https://github.com/flutter/flutter/issues/191069
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"piliplus", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
