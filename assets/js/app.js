// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/notex"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let mermaidClient = null

const loadMermaid = async () => {
  if (mermaidClient) return mermaidClient

  const mermaidModule = await import("../vendor/mermaid.min.js")

  mermaidClient = [mermaidModule.default, mermaidModule.mermaid, globalThis.mermaid]
    .find(candidate =>
      candidate &&
      typeof candidate.initialize === "function" &&
      typeof candidate.render === "function"
    )

  if (!mermaidClient) throw new Error("Mermaid failed to load")

  mermaidClient.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    theme: "base",
    themeVariables: {
      primaryColor: "#fefaff",
      primaryBorderColor: "#f3d9fa",
      primaryTextColor: "#5a2864",
      secondaryColor: "#fbfdff",
      secondaryBorderColor: "#dcecfb",
      secondaryTextColor: "#2d5274",
      tertiaryColor: "#fbfefc",
      tertiaryBorderColor: "#d9f2e2",
      tertiaryTextColor: "#2d6440",
      lineColor: "#e6dced",
      mainBkg: "#fefaff",
      secondBkg: "#fbfdff",
      tertiaryBkg: "#fbfefc",
      background: "#ffffff",
    },
  })

  return mermaidClient
}

const sanitizeMermaidMindmap = source => {
  const lines = source.split("\n")

  return lines.map(line => {
    const trimmed = line.trim()
    if (trimmed === "" || trimmed === "mindmap") return line

    return line
      .replace(/\s*\[[^\]]+\]/g, "")
      .replace(/[<>{}[\]|`"]/g, "")
  }).join("\n")
}

const Hooks = {
  ChatScroll: {
    mounted() {
      this.messageCount = this.el.children.length
      this.scrollToBottom()
    },
    updated() {
      const messageCount = this.el.children.length
      if (messageCount !== this.messageCount) {
        this.messageCount = messageCount
        this.scrollToBottom()
      }
    },
    scrollToBottom() {
      requestAnimationFrame(() => {
        this.el.scrollTop = this.el.scrollHeight
      })
    },
  },
  SpeechPlayer: {
    mounted() {
      this.handleClick = () => {
        if (!("speechSynthesis" in window)) return

        window.speechSynthesis.cancel()

        const text = this.el.dataset.text || ""
        const utterance = new SpeechSynthesisUtterance(text)
        utterance.lang = document.documentElement.lang || "en-US"
        window.speechSynthesis.speak(utterance)
      }

      this.el.addEventListener("click", this.handleClick)
    },
    destroyed() {
      this.el.removeEventListener("click", this.handleClick)
      if ("speechSynthesis" in window) window.speechSynthesis.cancel()
    },
  },
  MermaidRenderer: {
    mounted() {
      this.renderMermaid()
    },
    updated() {
      this.renderMermaid()
    },
    async renderMermaid() {
      const blocks = this.el.querySelectorAll(
        "pre > code.language-mermaid, pre > code.mermaid, pre > code[class*='language-mermaid']"
      )
      if (blocks.length === 0) return

      let mermaid

      try {
        mermaid = await loadMermaid()
      } catch (_error) {
        for (const block of blocks) {
          block.parentElement?.classList.add("studio-mermaid-error")
        }

        return
      }

      for (const block of blocks) {
        const pre = block.parentElement
        if (!pre || pre.dataset.mermaidRendered === "true") continue

        const rawSource = block.textContent || ""
        const source = rawSource.trimStart().startsWith("mindmap")
          ? sanitizeMermaidMindmap(rawSource)
          : rawSource
        const container = document.createElement("div")
        const id = `mermaid-${this.el.id}-${Math.random().toString(36).slice(2)}`

        container.className = "studio-mermaid"

        try {
          const {svg} = await mermaid.render(id, source)
          container.innerHTML = svg
          pre.replaceWith(container)
        } catch (_error) {
          pre.dataset.mermaidRendered = "true"
          pre.classList.add("studio-mermaid-error")
        }
      }
    },
  },
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

window.addEventListener("notex:flash-autohide", event => {
  const flash = event.target

  window.setTimeout(() => {
    if (document.body.contains(flash) && !flash.hasAttribute("hidden")) {
      flash.click()
    }
  }, 4000)
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
