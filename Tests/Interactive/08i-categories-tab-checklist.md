# Categories Tab Checklist

Nothing needed.

The Categories tab never touches the cube, so there is no physical action here. The one thing that
looked like it needed a person -- the **right-click context menu** that opens the inline rename --
turned out to be scriptable, so the whole rename flow lives in `Tests/Bench/08b` instead.

That took proving, because the menu is invisible to accessibility. The name element advertises an
`AXShowMenu` action which performs without error and opens nothing, and after a real right-click
`count of menus` still reports 0 on both the element and the process. A screenshot showed the menu
was on screen the entire time. So it is driven by coordinate: a `CGEventPost` right-click on the
element, then a left click at a small offset for the item. See
[Method 26](../Methods.md#method-26), and `cgevent_context_menu_pick` in the runner.

Same shape as `05i`, which was also believed to need a person until a held `CGEventPost` was shown
to reach the stepper arrows.

The two checks that genuinely need an eye -- the popover contents, and the **Active**/**Inactive**
section labels, which are not exposed to accessibility at all -- are `ask_user` steps inside `08b`.
They need a human *observer*, not a human *hand*, which is what keeps them on the Bench side: when
Claude runs the suite it answers them itself with a screenshot
([Method 17](../Methods.md#method-17)).
