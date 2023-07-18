import { html, useRef, useState, useLayoutEffect, useEffect } from "../imports/Preact.js"
import { open_pluto_popup } from "./Popup.js"

export const SlideControls = () => {
    const button_prev_ref = useRef(/** @type {HTMLButtonElement?} */ (null))
    const button_next_ref = useRef(/** @type {HTMLButtonElement?} */ (null))

    const [presenting, set_presenting] = useState(false)
    const [fullscreen, set_fullscreen] = useState(false)

    const move_slides_with_arrows = (/** @type {KeyboardEvent} */ e) => {
        const activeElement = document.activeElement
        if (
            activeElement != null &&
            activeElement !== document.body &&
            activeElement !== button_prev_ref.current &&
            activeElement !== button_next_ref.current
        ) {
            // We do not move slides with arrow if we have an active element
            return
        }
        if (e.key === "ArrowLeft") {
            button_prev_ref.current?.click()
        } else if (e.key === "ArrowRight") {
            button_next_ref.current?.click()
        } else {
            return
        }
        e.preventDefault()
    }

    const calculate_slide_positions = (/** @type {Event} */ e) => {
        const notebook_node = /** @type {HTMLElement?} */ (e.target)?.closest("pluto-editor")?.querySelector("pluto-notebook")
        if (!notebook_node) return []

        const height = window.innerHeight
        const headers = Array.from(notebook_node.querySelectorAll("pluto-output h1, pluto-output h2"))
        const pos = headers.map((el) => el.getBoundingClientRect())
        const edges = pos.map((rect) => rect.top + window.pageYOffset)

        edges.push(notebook_node.getBoundingClientRect().bottom + window.pageYOffset)

        const scrollPositions = headers.map((el, i) => {
            if (el.tagName == "H1") {
                // center vertically
                const slideHeight = edges[i + 1] - edges[i] - height
                return edges[i] - Math.max(0, (height - slideHeight) / 2)
            } else {
                // align to top
                return edges[i] - 20
            }
        })

        return scrollPositions
    }

    const go_previous_slide = (/** @type {Event} */ e) => {
        const positions = calculate_slide_positions(e)

        const pos = positions.reverse().find((y) => y < window.pageYOffset - 10)

        if (pos) window.scrollTo(window.pageXOffset, pos)
    }

    const go_next_slide = (/** @type {Event} */ e) => {
        const positions = calculate_slide_positions(e)
        const pos = positions.find((y) => y - 10 > window.pageYOffset)
        if (pos) window.scrollTo(window.pageXOffset, pos)
    }

    const presenting_ref = useRef(false)
    presenting_ref.current = presenting
    // @ts-ignore
    window.present = () => {
        set_presenting(!presenting_ref.current)
    }

    const fullscreen_ref = useRef(false)
    fullscreen_ref.current = fullscreen
    const check_fullscreen_status = (/** @type {UIEvent} */ e) => {
        // This will detect full screen if the window height becomes equivalent to the screen height
        // In firefox, screen.height is adapted based on OS DPI settings (at least on windows) and browser zoom, while on chrome the screen is not reflecting the browser zoom level. This means that the current approach will only work on chrome when the browser zoom is 100%.
        let maxHeight = window.screen.height
        let curHeight = window.innerHeight

        if (!fullscreen_ref.current && maxHeight === curHeight) {
            // We just got into FullScreen
            set_fullscreen(true)
        } else if (fullscreen_ref.current && maxHeight !== curHeight) {
            // We just got out of FullScreen
            set_fullscreen(false)
        } else {
            return
        }
    }

    useLayoutEffect(() => {
        document.body.classList.toggle("presentation", presenting)

        if (!presenting) return // We do not add listeners if not presenting

        window.addEventListener("keydown", move_slides_with_arrows)

        return () => {
            window.removeEventListener("keydown", move_slides_with_arrows)
        }
    }, [presenting])

    useLayoutEffect(() => {
        console.log("presenting")
        if (!presenting_ref.current && fullscreen) {
            open_pluto_popup({
                type: "info",
                source_element: null,
                body: html`It seems you have just entered fullscreen mode.
                    <p>Would you like to <b>activate</b> Pluto presentation mode?</p>
                    <a
                        href="#"
                        onClick=${(e) => {
                            e.preventDefault()
                            set_presenting(true)
                            window.dispatchEvent(new CustomEvent("close pluto popup"))
                        }}
                        >Yes</a
                    >
                    <br />
                    <a
                        href="#"
                        onClick=${(e) => {
                            e.preventDefault()
                            window.dispatchEvent(new CustomEvent("close pluto popup"))
                        }}
                        >No</a
                    >`,
            })
        } else if (presenting_ref.current && !fullscreen) {
            open_pluto_popup({
                type: "info",
                source_element: null,
                body: html`It seems you have just exited fullscreen mode.
                    <p>Would you like to <b>deactivate</b> Pluto presentation mode?</p>
                    <a
                        href="#"
                        onClick=${(e) => {
                            e.preventDefault()
                            set_presenting(false)
                            window.dispatchEvent(new CustomEvent("close pluto popup"))
                        }}
                        >Yes</a
                    >
                    <br />
                    <a
                        href="#"
                        onClick=${(e) => {
                            e.preventDefault()
                            window.dispatchEvent(new CustomEvent("close pluto popup"))
                        }}
                        >No</a
                    >`,
            })
        }
    }, [fullscreen])

    useEffect(() => {
        window.addEventListener("resize", check_fullscreen_status)

        return () => {
            window.removeEventListener("resize", check_fullscreen_status)
        }
    }, [])

    return html`
        <nav id="slide_controls">
            <button ref=${button_prev_ref} class="changeslide prev" title="Previous slide" onClick=${go_previous_slide}><span></span></button>
            <button ref=${button_next_ref} class="changeslide next" title="Next slide" onClick=${go_next_slide}><span></span></button>
        </nav>
    `
}
