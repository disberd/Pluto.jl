import { html, useState, useRef, useLayoutEffect, useEffect, useMemo, useContext } from "../imports/Preact.js"
import immer from "../imports/immer.js"
import observablehq from "../common/SetupCellEnvironment.js"
import { cl } from "../common/ClassTable.js"

import { RawHTMLContainer, highlight } from "./CellOutput.js"
import { PlutoActionsContext } from "../common/PlutoContext.js"
import { package_status, nbpkg_fingerprint_without_terminal } from "./PkgStatusMark.js"
import { PkgTerminalView } from "./PkgTerminalView.js"
import { useDebouncedTruth } from "./RunArea.js"

// This funny thing is a way to tell parcel to bundle these files..
// Eventually I'll write a plugin that is able to parse html`...`, but this is it for now.
// https://parceljs.org/languages/javascript/#url-dependencies
export const terminal_icon = new URL("https://cdn.jsdelivr.net/gh/ionic-team/ionicons@5.5.1/src/svg/terminal-outline.svg", import.meta.url)
export const arrow_up_circle_icon = new URL("https://cdn.jsdelivr.net/gh/ionic-team/ionicons@5.5.1/src/svg/arrow-up-circle-outline.svg", import.meta.url)
export const document_text_icon = new URL("https://cdn.jsdelivr.net/gh/ionic-team/ionicons@5.5.1/src/svg/document-text-outline.svg", import.meta.url)
export const help_circle_icon = new URL("https://cdn.jsdelivr.net/gh/ionic-team/ionicons@5.5.1/src/svg/help-circle-outline.svg", import.meta.url)

/**
 * @typedef PkgPopupDetails
 * @property {"nbpkg"} type
 * @property {HTMLElement?} source_element
 * @property {string} package_name
 * @property {boolean} is_disable_pkg
 */

/**
 * @typedef MiscPopupDetails
 * @property {string} type
 * @property {import("../imports/Preact.js").ReactElement} body
 * @property {HTMLElement?} source_element
 */

export const open_pluto_popup = (/** @type{PkgPopupDetails | MiscPopupDetails} */ detail) => {
    window.dispatchEvent(
        new CustomEvent("open pluto popup", {
            detail,
        })
    )
}

export const Popup = ({ notebook }) => {
    const [recent_event, set_recent_event] = useState(/** @type{(PkgPopupDetails | MiscPopupDetails)?} */ (null))
    const recent_source_element_ref = useRef(/** @type{HTMLElement?} */ (null))
    const pos_ref = useRef("")

    const open = (/** @type {CustomEvent} */ e) => {
        const el = e.detail.source_element
        recent_source_element_ref.current = el

        const elb = el.getBoundingClientRect()
        const bodyb = document.body.getBoundingClientRect()

        pos_ref.current = `top: ${0.5 * (elb.top + elb.bottom) - bodyb.top}px; left: min(max(0px,100vw - 251px - 30px), ${elb.right - bodyb.left}px);`
        set_recent_event(e.detail)
    }

    const close = () => {
        set_recent_event(null)
    }

    useEffect(() => {
        const onpointerdown = (e) => {
            if (e.target == null) return
            if (e.target.closest("pluto-popup") != null) return
            if (recent_source_element_ref.current == null) return
            if (recent_source_element_ref.current.contains(e.target)) return

            close()
        }
        const onkeydown = (e) => {
            if (e.key === "Escape") {
                close()
            }
        }
        window.addEventListener("open pluto popup", open)
        window.addEventListener("close pluto popup", close)
        window.addEventListener("pointerdown", onpointerdown)
        document.addEventListener("keydown", onkeydown)

        return () => {
            window.removeEventListener("open pluto popup", open)
            window.removeEventListener("close pluto popup", close)
            window.removeEventListener("pointerdown", onpointerdown)
            document.removeEventListener("keydown", onkeydown)
        }
    }, [])

    const type = recent_event?.type
    return html`<pluto-popup
        class=${cl({
            visible: recent_event != null,
        })}
        style="${pos_ref.current}"
    >
        ${type === "nbpkg"
            ? html`<${PkgPopup} notebook=${notebook} recent_event=${recent_event} clear_recent_event=${() => set_recent_event(null)} />`
            : type === "info"
            ? html`<div>${recent_event?.body}</div>`
            : null}
    </pluto-popup>`
}

/**
 * @param {{
 * notebook: import("./Editor.js").NotebookData,
 * recent_event: PkgPopupDetails,
 * clear_recent_event: () => void,
 * }} props
 */
const PkgPopup = ({ notebook, recent_event, clear_recent_event }) => {
    let pluto_actions = useContext(PlutoActionsContext)
    const [pkg_status, set_pkg_status] = useState(/** @type{import("./PkgStatusMark.js").PackageStatus?} */ (null))

    useEffect(() => {
        let still_valid = true
        if (recent_event == null) {
            set_pkg_status(null)
        } else if (recent_event?.type === "nbpkg") {
            ;(pluto_actions.get_avaible_versions({ package_name: recent_event.package_name, notebook_id: notebook.notebook_id }) ?? Promise.resolve([])).then(
                (versions) => {
                    if (still_valid) {
                        set_pkg_status(
                            package_status({
                                nbpkg: notebook.nbpkg,
                                package_name: recent_event.package_name,
                                is_disable_pkg: recent_event.is_disable_pkg,
                                available_versions: versions,
                            })
                        )
                    }
                }
            )
        }
        return () => {
            still_valid = false
        }
    }, [recent_event, ...nbpkg_fingerprint_without_terminal(notebook.nbpkg)])

    // hide popup when nbpkg is switched on/off
    useEffect(() => {
        if (!(notebook.nbpkg?.enabled ?? true)) {
            clear_recent_event()
        }
    }, [notebook.nbpkg?.enabled ?? true])

    const [showterminal, set_showterminal] = useState(false)

    const package_name = recent_event?.package_name
    const default_pkg_str = `add ${recent_event.package_name}`
    const pkg_str = (notebook.nbpkg?.installed_pkgstrs ?? {}).hasOwnProperty(package_name) ? notebook.nbpkg?.installed_pkgstrs[package_name] : default_pkg_str

    const busy = recent_event != null && ((notebook.nbpkg?.busy_packages ?? []).includes(package_name) || !(notebook.nbpkg?.instantiated ?? true))

    const debounced_busy = useDebouncedTruth(busy, 2)
    useEffect(() => {
        set_showterminal(debounced_busy)
    }, [debounced_busy])

    const terminal_value = notebook.nbpkg?.terminal_outputs == null ? "Loading..." : notebook.nbpkg?.terminal_outputs[package_name] ?? ""

    const showupdate = pkg_status?.offer_update ?? false

    async function try_update_pkgstr(message, _default) {
        const new_pkg_str = prompt(message, _default) ?? pkg_str
        const result = await pluto_actions.send(
            "pkg_str",
            { package_name: recent_event.package_name, pkg_str: new_pkg_str },
            { notebook_id: notebook.notebook_id }
        )
        if (result.message.errored) {
            try_update_pkgstr(result.message.message, new_pkg_str)
        }
    }

    // <header>${recent_event?.package_name}</header>
    return html`<pkg-popup
        class=${cl({
            busy,
            showterminal,
            showupdate,
        })}
    >
        ${pkg_status?.hint ?? "Loading..."}
        <div class="pkg-buttons">
            <a
                class="pkg-str"
                target="_blank"
                title="Use custom PkgREPL string"
                href="#"
                onClick=${(e) => {
                    e.preventDefault()
                    try_update_pkgstr("Write the custom string to install the package", pkg_str)
                }}
                ><img alt="💻" src=${terminal_icon} width="17"
            /></a>
            <a
                class="pkg-update"
                target="_blank"
                title="Update packages"
                style=${(!!showupdate ? "" : "opacity: .4;") + (recent_event?.is_disable_pkg ? "display: none;" : "")}
                href="#"
                onClick=${(e) => {
                    if (busy) {
                        alert("Pkg is currently busy with other packages... come back later!")
                    } else {
                        if (confirm("Would you like to check for updates and install them? A backup of the notebook file will be created.")) {
                            console.warn("Pkg.updating!")
                            pluto_actions.send("pkg_update", {}, { notebook_id: notebook.notebook_id })
                        }
                    }
                    e.preventDefault()
                }}
                ><img alt="⬆️" src=${arrow_up_circle_icon} width="17"
            /></a>
            <a
                class="toggle-terminal"
                target="_blank"
                title="Show/hide Pkg terminal output"
                style=${!!terminal_value ? "" : "display: none;"}
                href="#"
                onClick=${(e) => {
                    set_showterminal(!showterminal)
                    e.preventDefault()
                }}
                ><img alt="📄" src=${document_text_icon} width="17"
            /></a>
            <a class="help" target="_blank" title="Go to help page" href="https://github.com/fonsp/Pluto.jl/wiki/%F0%9F%8E%81-Package-management"
                ><img alt="❔" src=${help_circle_icon} width="17"
            /></a>
        </div>
        <${PkgTerminalView} value=${terminal_value ?? "Loading..."} />
    </pkg-popup>`
}
