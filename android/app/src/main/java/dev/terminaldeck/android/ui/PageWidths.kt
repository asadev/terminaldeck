package dev.terminaldeck.android.ui

/**
 * The device sizes the machine-window screen can lay a page out at.
 *
 * A port of the device list in `ios/TerminalDeck/Ports/PageWidths.swift` (`PageDevice`), the desktop
 * device toolbar on the phone that is holding the page:
 *
 *   > *"they can pinch and zoom also they can see all the different dimensions in responsive views how
 *   > it will look like in mobile how it will look like on Windows so they can have different
 *   > dimensions also in phone just like MacBook."*
 *
 * A chosen device is a **real rectangle in CSS pixels** — a laptop is 1280 × 800 whatever phone is
 * looking at it — and it reaches the machine as `browser.window.size`, which reflows the document over
 * there. That is the honest answer to *"how will this look on a laptop"*, and the reason it is a size
 * sent to the machine rather than a scale applied to the picture: a layout answers through
 * `@media (min-width: 1024px)`, which fires off the viewport and not off how big the result is drawn.
 * Pinch on the cast is the other half — it magnifies the picture and leaves the layout alone, exactly
 * as a desktop's device toolbar does at 30%.
 *
 * [ThisPhone] is where every window starts and the way back: the window laid out at the phone's own
 * view size, with no rectangle imposed. The set is a list of real ones rather than a slider, because
 * *"Laptop 1280 × 800"* is a name to point at and a number to check, where a slider from 320 to 2560
 * asks the reader to already know the answer.
 *
 * The numbers are breakpoint neighbourhoods rather than named products, so a case does not date the
 * moment a model changes size — the same seven iOS offers, in the same order.
 */
enum class PageDevice(val label: String, val width: Int?, val height: Int?) {
    /** This phone's own size: no frame imposed on the machine. The default, and the way back. */
    ThisPhone("This phone", null, null),

    /** The narrow floor — every responsive framework's smallest breakpoint, and still real hardware. */
    SmallPhone("Small phone", 320, 568),

    /** The phone class most people are holding. */
    Phone("Phone", 390, 844),

    /** The large-phone class, where a two-column layout first tries to appear. */
    LargePhone("Large phone", 430, 932),

    /** A tablet upright. */
    Tablet("Tablet", 834, 1194),

    /** The same tablet on its side — its own row, because *"how does this look on an iPad"* is nearly
     *  always asked about the landscape one, and one tap is the right price for the common question. */
    TabletLandscape("Tablet landscape", 1194, 834),

    /** A laptop's usable browser box, a MacBook Air's. */
    Laptop("Laptop", 1280, 800),

    /** The desktop one, where a Windows machine at 1920 puts a maximised window once scaling applies. */
    Desktop("Desktop", 1440, 900);

    /**
     * The pixels, for the quiet half of a row — `1280 × 800`, a multiplication sign rather than an
     * `x` because this is the one place the feature prints a dimension and it should look like one.
     *
     * Null for [ThisPhone], whose size is whatever the phone is and is not a fact worth printing.
     */
    val measure: String? get() = if (width != null && height != null) "$width × $height" else null
}
