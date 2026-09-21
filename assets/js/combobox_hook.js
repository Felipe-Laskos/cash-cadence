const fold = (text) => text.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase()

const foldWithMap = (text) => {
  let folded = ""
  let at = 0
  const origin = []

  for (const char of text) {
    const piece = fold(char)
    folded += piece
    for (let i = 0; i < piece.length; i++) origin.push(at)
    at += char.length
  }

  origin.push(text.length)
  return {folded, origin}
}

const match = (text, needle) => {
  if (needle === "") return {from: 0, to: 0}

  const {folded, origin} = foldWithMap(text)
  const at = folded.indexOf(needle)

  return at === -1 ? null : {from: origin[at], to: origin[at + needle.length]}
}

const parse = (json) => {
  try {
    return JSON.parse(json || "[]")
  } catch {
    return []
  }
}

export default {
  mounted() {
    this.list = document.getElementById(`${this.el.id}-listbox`)
    this.options = parse(this.el.dataset.options)
    this.rows = []
    this.active = -1

    this.onInput = () => {
      if (!this.chose) this.open()
    }
    this.onClick = () => this.open()
    this.onKeyDown = (event) => this.keydown(event)
    this.onBlur = () => this.close()
    this.onOutside = (event) => {
      if (event.target !== this.el && !this.list.contains(event.target)) this.close()
    }

    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("keydown", this.onKeyDown)
    this.el.addEventListener("blur", this.onBlur)
    document.addEventListener("mousedown", this.onOutside)

    this.list.addEventListener("mousedown", (event) => event.preventDefault())
    this.list.addEventListener("click", (event) => {
      const row = event.target.closest("[data-value]")
      if (row) this.choose(row.dataset.value)
    })
    this.list.addEventListener("mousemove", (event) => {
      const row = event.target.closest("[data-value]")
      if (!row) return

      const index = Array.prototype.indexOf.call(this.list.children, row)
      if (index !== this.active) this.highlight(index, false)
    })
  },

  updated() {
    this.options = parse(this.el.dataset.options)
    if (!this.list.hidden) this.open()
  },

  destroyed() {
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("keydown", this.onKeyDown)
    this.el.removeEventListener("blur", this.onBlur)
    document.removeEventListener("mousedown", this.onOutside)
  },

  open() {
    const needle = fold(this.el.value.trim())

    this.rows = this.options
      .map((option) => ({option, hit: match(option.value, needle)}))
      .filter((row) => row.hit)
      .sort((a, b) => a.hit.from - b.hit.from)

    if (this.rows.length === 0) return this.close()

    this.list.replaceChildren(...this.rows.map((row, index) => this.row(row, index)))
    this.list.hidden = false
    this.el.setAttribute("aria-expanded", "true")
    this.highlight(needle === "" ? -1 : 0)
  },

  close() {
    this.list.hidden = true
    this.list.replaceChildren()
    this.el.setAttribute("aria-expanded", "false")
    this.el.removeAttribute("aria-activedescendant")
    this.active = -1
  },

  row({option, hit}, index) {
    const item = document.createElement("li")
    item.id = `${this.el.id}-option-${index}`
    item.setAttribute("role", "option")
    item.dataset.value = option.value
    item.className =
      "flex cursor-pointer items-center justify-between gap-3 px-3 py-2 text-sm transition-colors"

    const name = document.createElement("span")
    name.className = "truncate"

    if (hit.to > hit.from) {
      const strong = document.createElement("mark")
      strong.className = "bg-transparent font-bold text-primary"
      strong.textContent = option.value.slice(hit.from, hit.to)
      name.append(option.value.slice(0, hit.from), strong, option.value.slice(hit.to))
    } else {
      name.textContent = option.value
    }

    item.append(name)

    if (option.hint) {
      const hint = document.createElement("span")
      hint.className = "shrink-0 text-xs text-base-content/50"
      hint.textContent = option.hint
      item.append(hint)
    }

    return item
  },

  highlight(index, scroll = true) {
    this.active = index

    Array.from(this.list.children).forEach((item, at) => {
      const on = at === index
      item.setAttribute("aria-selected", String(on))
      item.classList.toggle("bg-base-300", on)
    })

    if (index < 0) return this.el.removeAttribute("aria-activedescendant")

    const item = this.list.children[index]
    this.el.setAttribute("aria-activedescendant", item.id)
    if (scroll) item.scrollIntoView({block: "nearest"})
  },

  move(step) {
    if (this.list.hidden) this.open()
    if (this.list.hidden) return

    const total = this.rows.length
    const first = step > 0 ? 0 : total - 1

    this.highlight(this.active < 0 ? first : (this.active + step + total) % total)
  },

  choose(value) {
    this.el.value = value
    this.el.setSelectionRange(value.length, value.length)
    this.close()
    this.chose = true
    this.el.dispatchEvent(new Event("input", {bubbles: true}))
    this.chose = false
    this.el.focus()
  },

  keydown(event) {
    if (event.isComposing || event.altKey || event.ctrlKey || event.metaKey) return

    switch (event.key) {
      case "ArrowDown":
        event.preventDefault()
        this.move(1)
        break
      case "ArrowUp":
        event.preventDefault()
        this.move(-1)
        break
      case "Enter": {
        if (event.shiftKey) return
        const row = this.rows[this.active]
        if (this.list.hidden || !row) return
        event.preventDefault()
        this.choose(row.option.value)
        break
      }
      case "Escape":
        if (this.list.hidden) return
        event.preventDefault()
        event.stopPropagation()
        this.close()
        break
      case "Tab":
        this.close()
        break
    }
  },
}
