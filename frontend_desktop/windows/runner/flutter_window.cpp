#include "flutter_window.h"

#include <exdisp.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shlwapi.h>

#include <algorithm>
#include <cwctype>
#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return L"";
  }
  const int len = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (len <= 0) {
    return L"";
  }
  std::wstring out(static_cast<size_t>(len), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                        static_cast<int>(utf8.size()), &out[0], len);
  return out;
}

std::wstring NormalizeWinPathForCompare(std::wstring path) {
  std::replace(path.begin(), path.end(), L'/', L'\\');
  while (path.size() > 3 && path.back() == L'\\') {
    path.pop_back();
  }
  for (wchar_t& ch : path) {
    ch = static_cast<wchar_t>(std::towlower(ch));
  }
  return path;
}

std::wstring ExtractParentFolder(const std::wstring& path) {
  std::wstring clean = path;
  std::replace(clean.begin(), clean.end(), L'/', L'\\');
  const size_t pos = clean.find_last_of(L'\\');
  if (pos == std::wstring::npos) {
    return L"";
  }
  if (pos == 2 && clean.size() >= 3 && clean[1] == L':') {
    return clean.substr(0, 3);
  }
  return clean.substr(0, pos);
}

HWND FindExplorerWindowForFolder(const std::wstring& normalizedFolder) {
  if (normalizedFolder.empty()) {
    return nullptr;
  }
  IShellWindows* shell_windows = nullptr;
  const HRESULT hr_create = ::CoCreateInstance(
      CLSID_ShellWindows, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&shell_windows));
  if (FAILED(hr_create) || shell_windows == nullptr) {
    return nullptr;
  }

  HWND matched_hwnd = nullptr;
  long count = 0;
  if (SUCCEEDED(shell_windows->get_Count(&count))) {
    for (long i = 0; i < count && matched_hwnd == nullptr; ++i) {
      VARIANT v_idx;
      ::VariantInit(&v_idx);
      v_idx.vt = VT_I4;
      v_idx.lVal = i;

      IDispatch* disp = nullptr;
      if (SUCCEEDED(shell_windows->Item(v_idx, &disp)) && disp != nullptr) {
        IWebBrowserApp* web_app = nullptr;
        if (SUCCEEDED(disp->QueryInterface(IID_PPV_ARGS(&web_app))) &&
            web_app != nullptr) {
          BSTR url_bstr = nullptr;
          if (SUCCEEDED(web_app->get_LocationURL(&url_bstr)) &&
              url_bstr != nullptr) {
            wchar_t path_buf[4096];
            DWORD path_len = static_cast<DWORD>(sizeof(path_buf) / sizeof(path_buf[0]));
            if (SUCCEEDED(::PathCreateFromUrlW(url_bstr, path_buf, &path_len, 0))) {
              if (NormalizeWinPathForCompare(path_buf) == normalizedFolder) {
                SHANDLE_PTR handle_ptr = 0;
                if (SUCCEEDED(web_app->get_HWND(&handle_ptr)) &&
                    handle_ptr != 0) {
                  matched_hwnd = reinterpret_cast<HWND>(handle_ptr);
                }
              }
            }
            ::SysFreeString(url_bstr);
          }
          web_app->Release();
        }
        disp->Release();
      }
      ::VariantClear(&v_idx);
    }
  }
  shell_windows->Release();
  return matched_hwnd;
}

void BringExplorerWindowToFront(HWND explorer_hwnd, HWND owner_hwnd) {
  if (explorer_hwnd == nullptr || !::IsWindow(explorer_hwnd)) {
    return;
  }
  FLASHWINFO fi{};
  fi.cbSize = sizeof(fi);
  fi.hwnd = explorer_hwnd;
  fi.dwFlags = FLASHW_STOP;
  ::FlashWindowEx(&fi);

  if (::IsIconic(explorer_hwnd) != FALSE) {
    ::ShowWindow(explorer_hwnd, SW_RESTORE);
  } else if (::IsWindowVisible(explorer_hwnd) == FALSE) {
    ::ShowWindow(explorer_hwnd, SW_SHOW);
  }

  if (::GetForegroundWindow() != explorer_hwnd) {
    ::AllowSetForegroundWindow(ASFW_ANY);
    ::SetWindowPos(explorer_hwnd, HWND_TOP, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
    ::BringWindowToTop(explorer_hwnd);
    if (::SetForegroundWindow(explorer_hwnd) == FALSE &&
        owner_hwnd != nullptr && ::GetForegroundWindow() == owner_hwnd) {
      DWORD owner_tid = ::GetWindowThreadProcessId(owner_hwnd, nullptr);
      DWORD target_tid = ::GetWindowThreadProcessId(explorer_hwnd, nullptr);
      if (owner_tid != 0 && target_tid != 0 && owner_tid != target_tid) {
        ::AttachThreadInput(owner_tid, target_tid, TRUE);
        ::SetWindowPos(explorer_hwnd, HWND_TOP, 0, 0, 0, 0,
                       SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        ::SetForegroundWindow(explorer_hwnd);
        ::BringWindowToTop(explorer_hwnd);
        ::AttachThreadInput(owner_tid, target_tid, FALSE);
      }
    }
  }
}

bool OpenInExplorerNative(const std::wstring& raw_path, HWND owner_hwnd) {
  if (raw_path.empty()) {
    return false;
  }
  std::wstring clean_path = raw_path;
  std::replace(clean_path.begin(), clean_path.end(), L'/', L'\\');
  while (clean_path.size() > 3 && clean_path.back() == L'\\') {
    clean_path.pop_back();
  }

  DWORD attrs = ::GetFileAttributesW(clean_path.c_str());
  bool is_file = false;
  std::wstring folder_path;
  if (attrs != INVALID_FILE_ATTRIBUTES) {
    if ((attrs & FILE_ATTRIBUTE_DIRECTORY) == 0) {
      is_file = true;
      folder_path = ExtractParentFolder(clean_path);
    } else {
      folder_path = clean_path;
    }
  } else {
    std::wstring probe = ExtractParentFolder(clean_path);
    while (!probe.empty()) {
      const DWORD p_attrs = ::GetFileAttributesW(probe.c_str());
      if (p_attrs != INVALID_FILE_ATTRIBUTES &&
          (p_attrs & FILE_ATTRIBUTE_DIRECTORY) != 0) {
        folder_path = probe;
        break;
      }
      const std::wstring next_probe = ExtractParentFolder(probe);
      if (next_probe == probe) {
        break;
      }
      probe = next_probe;
    }
  }

  if (folder_path.empty()) {
    return false;
  }

  const std::wstring norm_folder = NormalizeWinPathForCompare(folder_path);
  bool launched = false;

  ::AllowSetForegroundWindow(ASFW_ANY);

  if (is_file) {
    PIDLIST_ABSOLUTE item_pidl = ::ILCreateFromPathW(clean_path.c_str());
    if (item_pidl != nullptr) {
      PIDLIST_ABSOLUTE folder_pidl = ::ILClone(item_pidl);
      if (folder_pidl != nullptr) {
        ::ILRemoveLastID(folder_pidl);
        PCUITEMID_CHILD child_pidl = ::ILFindLastID(item_pidl);
        const HRESULT hr =
            ::SHOpenFolderAndSelectItems(folder_pidl, 1, &child_pidl, 0);
        if (SUCCEEDED(hr)) {
          launched = true;
        }
        ::ILFree(folder_pidl);
      }
      ::ILFree(item_pidl);
    }
    if (!launched) {
      const std::wstring params = L"/select,\"" + clean_path + L"\"";
      HINSTANCE res =
          ::ShellExecuteW(owner_hwnd, L"open", L"explorer.exe", params.c_str(),
                          nullptr, SW_SHOWNORMAL);
      launched = reinterpret_cast<INT_PTR>(res) > 32;
    }
  } else {
    HINSTANCE res = ::ShellExecuteW(owner_hwnd, L"open", folder_path.c_str(),
                                    nullptr, nullptr, SW_SHOWNORMAL);
    launched = reinterpret_cast<INT_PTR>(res) > 32;
    if (!launched) {
      const std::wstring params = L"\"" + folder_path + L"\"";
      res = ::ShellExecuteW(owner_hwnd, L"open", L"explorer.exe",
                            params.c_str(), nullptr, SW_SHOWNORMAL);
      launched = reinterpret_cast<INT_PTR>(res) > 32;
    }
  }

  if (!launched) {
    return false;
  }

  HWND explorer_hwnd = FindExplorerWindowForFolder(norm_folder);
  for (int attempt = 0; explorer_hwnd == nullptr && attempt < 6; ++attempt) {
    ::Sleep(35);
    explorer_hwnd = FindExplorerWindowForFolder(norm_folder);
  }
  if (explorer_hwnd != nullptr) {
    BringExplorerWindowToFront(explorer_hwnd, owner_hwnd);
  }
  return true;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetupWindowChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
    this->NotifyMaximizeChangedIfNeeded();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::SetupWindowChannel() {
  if (!flutter_controller_ || !flutter_controller_->engine()) {
    return;
  }
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "media_workflow_x/window",
          &flutter::StandardMethodCodec::GetInstance());

  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HWND hwnd = this->GetHandle();
        if (hwnd == nullptr) {
          result->Error("NO_WINDOW", "Native window handle is unavailable.");
          return;
        }

        const std::string& method = call.method_name();
        if (method == "minimize") {
          ::ShowWindow(hwnd, SW_MINIMIZE);
          result->Success();
        } else if (method == "maximize") {
          ::ShowWindow(hwnd, SW_MAXIMIZE);
          this->NotifyMaximizeChangedIfNeeded();
          result->Success();
        } else if (method == "unmaximize") {
          ::ShowWindow(hwnd, SW_RESTORE);
          this->NotifyMaximizeChangedIfNeeded();
          result->Success();
        } else if (method == "toggleMaximize") {
          ::ShowWindow(hwnd, ::IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
          this->NotifyMaximizeChangedIfNeeded();
          result->Success(flutter::EncodableValue(::IsZoomed(hwnd) != FALSE));
        } else if (method == "isMaximized") {
          result->Success(flutter::EncodableValue(::IsZoomed(hwnd) != FALSE));
        } else if (method == "close") {
          result->Success();
          ::PostMessage(hwnd, WM_CLOSE, 0, 0);
        } else if (method == "startDragging") {
          result->Success();
          ::ReleaseCapture();
          POINT pt{};
          ::GetCursorPos(&pt);
          ::SendMessage(hwnd, WM_NCLBUTTONDOWN, HTCAPTION,
                        MAKELPARAM(pt.x, pt.y));
        } else if (method == "startResize") {
          WPARAM hit_test = HTTOP;
          if (const auto* edge = std::get_if<std::string>(call.arguments())) {
            if (*edge == "topLeft") {
              hit_test = HTTOPLEFT;
            } else if (*edge == "topRight") {
              hit_test = HTTOPRIGHT;
            }
          }
          result->Success();
          if (::IsZoomed(hwnd) == FALSE) {
            ::ReleaseCapture();
            POINT pt{};
            ::GetCursorPos(&pt);
            ::SendMessage(hwnd, WM_NCLBUTTONDOWN, hit_test,
                          MAKELPARAM(pt.x, pt.y));
          }
        } else if (method == "showSystemMenu") {
          result->Success();
          HMENU menu = ::GetSystemMenu(hwnd, FALSE);
          if (menu != nullptr) {
            const bool zoomed = ::IsZoomed(hwnd) != FALSE;
            ::EnableMenuItem(
                menu, SC_RESTORE,
                MF_BYCOMMAND | (zoomed ? MF_ENABLED : MF_GRAYED));
            ::EnableMenuItem(
                menu, SC_MOVE,
                MF_BYCOMMAND | (zoomed ? MF_GRAYED : MF_ENABLED));
            ::EnableMenuItem(
                menu, SC_SIZE,
                MF_BYCOMMAND | (zoomed ? MF_GRAYED : MF_ENABLED));
            ::EnableMenuItem(menu, SC_MINIMIZE, MF_BYCOMMAND | MF_ENABLED);
            ::EnableMenuItem(
                menu, SC_MAXIMIZE,
                MF_BYCOMMAND | (zoomed ? MF_GRAYED : MF_ENABLED));
            ::EnableMenuItem(menu, SC_CLOSE, MF_BYCOMMAND | MF_ENABLED);
            POINT pt{};
            ::GetCursorPos(&pt);
            const UINT cmd = ::TrackPopupMenu(
                menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY,
                pt.x, pt.y, 0, hwnd, nullptr);
            if (cmd != 0) {
              ::PostMessage(hwnd, WM_SYSCOMMAND, static_cast<WPARAM>(cmd), 0);
            }
          }
        } else if (method == "openInExplorer") {
          const auto* path_arg = std::get_if<std::string>(call.arguments());
          if (path_arg == nullptr || path_arg->empty()) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          const std::wstring wide_path = Utf8ToWide(*path_arg);
          const bool ok = OpenInExplorerNative(wide_path, hwnd);
          result->Success(flutter::EncodableValue(ok));
        } else {
          result->NotImplemented();
        }
      });
}

void FlutterWindow::NotifyMaximizeChangedIfNeeded() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || !window_channel_) {
    return;
  }
  const bool zoomed = ::IsZoomed(hwnd) != FALSE;
  if (zoomed != last_is_maximized_) {
    last_is_maximized_ = zoomed;
    window_channel_->InvokeMethod(
        "onWindowMaximizeChanged",
        std::make_unique<flutter::EncodableValue>(zoomed));
  }
}

void FlutterWindow::OnDestroy() {
  if (window_channel_) {
    window_channel_->SetMethodCallHandler(nullptr);
    window_channel_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_SIZE: {
      LRESULT base_res =
          Win32Window::MessageHandler(hwnd, message, wparam, lparam);
      NotifyMaximizeChangedIfNeeded();
      return base_res;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
