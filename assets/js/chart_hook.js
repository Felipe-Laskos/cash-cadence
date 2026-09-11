import Chart from "../vendor/chart.umd.js"

const brl = new Intl.NumberFormat("pt-BR", {style: "currency", currency: "BRL"})
const compact = new Intl.NumberFormat("pt-BR", {notation: "compact", maximumFractionDigits: 1})

const cssVar = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim()
const resolve = (color) => (color && color.startsWith("--") ? cssVar(color) : color)

const barConfig = (data) => ({
  type: "bar",
  data: {
    labels: data.labels,
    datasets: data.datasets.map((ds) => ({
      label: ds.label,
      data: ds.data,
      backgroundColor: resolve(ds.color),
      borderRadius: 4,
      borderSkipped: "bottom",
      maxBarThickness: 44,
      categoryPercentage: 0.6,
      barPercentage: 0.9,
    })),
  },
  options: {
    responsive: true,
    maintainAspectRatio: false,
    animation: {duration: 250},
    plugins: {
      legend: {display: false},
      tooltip: {callbacks: {label: (ctx) => `${ctx.dataset.label}: ${brl.format(ctx.parsed.y)}`}},
    },
    scales: {
      x: {grid: {display: false}, ticks: {color: cssVar("--chart-text"), font: {weight: 600}}},
      y: {
        beginAtZero: true,
        border: {display: false},
        grid: {color: cssVar("--chart-grid")},
        ticks: {color: cssVar("--chart-text"), callback: (v) => compact.format(v)},
      },
    },
  },
})

const doughnutConfig = (data) => ({
  type: "doughnut",
  data: {
    labels: data.labels,
    datasets: data.datasets.map((ds) => ({
      data: ds.data,
      backgroundColor: ds.colors.map(resolve),
      borderColor: cssVar("--color-base-100"),
      borderWidth: 2,
      hoverOffset: 4,
    })),
  },
  options: {
    responsive: true,
    maintainAspectRatio: false,
    cutout: "70%",
    animation: {duration: 250},
    plugins: {
      legend: {display: false},
      tooltip: {
        callbacks: {
          label: (ctx) => {
            const total = ctx.dataset.data.reduce((a, b) => a + b, 0)
            const pct = total > 0 ? Math.round((ctx.parsed / total) * 100) : 0
            return `${ctx.label}: ${brl.format(ctx.parsed)} (${pct}%)`
          },
        },
      },
    },
  },
})

const build = (data) => (data.type === "doughnut" ? doughnutConfig(data) : barConfig(data))

export default {
  mounted() {
    this.render(JSON.parse(this.el.dataset.chart))
    this.handleEvent(`chart:${this.el.id}`, (data) => this.render(data))
    this.observer = new MutationObserver(() => this.data && this.render(this.data))
    this.observer.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})
  },

  destroyed() {
    this.observer?.disconnect()
    this.chart?.destroy()
  },

  render(data) {
    this.data = data
    this.chart?.destroy()
    this.chart = new Chart(this.el.querySelector("canvas"), build(data))
  },
}
