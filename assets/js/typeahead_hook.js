const fold = (text) =>
  text
    .normalize("NFD")
    .replace(/\p{Diacritic}/gu, "")
    .trim()
    .toLowerCase()

const values = (list) =>
  list ? Array.from(list.options, (option) => option.value).filter((value) => value !== "") : []

const completion = (options, typed) => {
  const needle = fold(typed)
  if (needle === "") return null

  const match =
    options.find((option) => fold(option).startsWith(needle)) ||
    options.find((option) => fold(option).includes(needle)) ||
    null

  return match === typed ? null : match
}

export default {
  mounted() {
    this.onKeyDown = (event) => {
      if (event.key !== "Enter" || event.isComposing) return
      if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return

      const match = completion(values(this.el.list), this.el.value)
      if (!match) return

      event.preventDefault()
      this.el.value = match
      this.el.setSelectionRange(match.length, match.length)
      this.el.dispatchEvent(new Event("input", {bubbles: true}))
    }

    this.el.addEventListener("keydown", this.onKeyDown)
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKeyDown)
  },
}
