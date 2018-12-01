#pragma once

#include <Windows.h>
#include <functional>

namespace wr
{

	class Window
	{
		using KeyCallback = std::function<void(int key, int action, int mods)>;
		using ResizeCallback = std::function<void(std::uint32_t width, std::uint32_t height)>;
	public:
		/*!
		* @param instance A handle to the current instance of the application.
		* @param name Window title.
		* @param width Initial window width.
		* @param height Initial window height.
		* @param show Controls whether the window will be shown. Default is true.
		*/
		Window(HINSTANCE instance, std::string const& name, std::uint32_t width, std::uint32_t height, bool show = true);
		Window(HINSTANCE instance, int show_cmd, std::string const& name, std::uint32_t width, std::uint32_t height);
		~Window();

		Window(const Window&) = delete;
		Window& operator=(const Window&) = delete;
		Window(Window&&) = delete;
		Window& operator=(Window&&) = delete;

		/*! Handles window events. Should be called every frame */
		void PollEvents();
		/*! Shows the window if it was hidden */
		void Show();
		/*! Requests to close the window */
		void Stop();

		/*! Used to set the key callback function */
		void SetKeyCallback(KeyCallback callback);
		/*! Used to set the resize callback function */
		void SetResizeCallback(ResizeCallback callback);

		/*! Returns whether the application is running. (used for the main loop) */
		bool IsRunning() const;
		/* Returns the client width */
		std::int32_t GetWidth() const;
		/* Returns the client height */
		std::int32_t GetHeight() const;
		/*! Returns the native window handle (HWND)*/
		HWND GetWindowHandle() const;
		/*! Checks whether the window is fullscreen */
		bool IsFullscreen() const;

	private:
		/*! WindowProc that calls `WindowProc_Impl` */
		static LRESULT CALLBACK WindowProc(HWND, UINT, WPARAM, LPARAM);
		/*! Main WindowProc function */
		LRESULT CALLBACK WindowProc_Impl(HWND, UINT, WPARAM, LPARAM);

		KeyCallback m_key_callback;
		ResizeCallback m_resize_callback;

		bool m_running;
		HWND m_handle;
	};

} /* wr */