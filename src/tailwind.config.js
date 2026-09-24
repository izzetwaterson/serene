/** Tailwind yapılandırması — mockup'taki tema birebir korunmuştur. */
module.exports = {
  darkMode: "class",
  content: ["./index.html", "./app.js"],
  theme: {
    extend: {
      colors: {
        "surface-dim": "#dbd7cf",
        "on-surface": "#2e3230",
        "on-primary-fixed": "#002110",
        "secondary-fixed-dim": "#d4ccbf",
        "secondary-container": "#f0e8db",
        "tertiary-fixed-dim": "#dcc48e",
        "on-secondary-container": "#5e5548",
        "error-container": "#fce4e2",
        "on-primary-fixed-variant": "#2a6038",
        "on-secondary-fixed": "#1e1a13",
        "surface-variant": "#e9e4db",
        "on-surface-variant": "#5f6660",
        "on-tertiary-fixed": "#221a05",
        "on-tertiary-container": "#554020",
        "outline-variant": "#dcd8ce",
        "on-error-container": "#7a1a18",
        "inverse-surface": "#2e3230",
        "tertiary-fixed": "#f8e0a8",
        "surface-container-high": "#ebe5dc",
        "surface-container": "#f2eee6",
        "surface-tint": "#4a7c59",
        "surface-bright": "#faf7f2",
        outline: "#8a9088",
        "on-secondary-fixed-variant": "#4a4538",
        "surface-container-highest": "#e2ded5",
        "primary-container": "#4a7c59",
        "on-error": "#ffffff",
        primary: "#3d6a4b",
        secondary: "#6b6358",
        "surface-container-lowest": "#ffffff",
        tertiary: "#a86b32",
        "on-secondary": "#ffffff",
        "on-tertiary": "#ffffff",
        "secondary-fixed": "#f0e8db",
        background: "#f7f4ed",
        "inverse-primary": "#8ecf9e",
        error: "#b83230",
        "primary-fixed-dim": "#8ecf9e",
        "on-tertiary-fixed-variant": "#554020",
        "on-primary-container": "#ffffff",
        "on-background": "#2a2e2b",
        "inverse-on-surface": "#f5f0e8",
        "surface-container-low": "#faf7f1",
        "tertiary-container": "#eedfcc",
        surface: "#f7f4ed",
        "on-primary": "#ffffff",
        "primary-fixed": "#d3ebd8"
      },
      fontFamily: {
        headline: ["Fraunces", "serif"],
        display: ["Fraunces", "serif"],
        body: ["Nunito Sans", "sans-serif"],
        mono: ["JetBrains Mono", "monospace"]
      },
      boxShadow: {
        soft: "0 2px 14px -2px rgba(60, 52, 42, 0.04), 0 1px 3px rgba(60, 52, 42, 0.03)",
        float: "0 10px 30px -6px rgba(50, 40, 30, 0.07), 0 2px 8px -2px rgba(50, 40, 30, 0.04)",
        "inner-soft": "inset 0 1px 2px rgba(0, 0, 0, 0.03)"
      }
    }
  },
  plugins: []
};
