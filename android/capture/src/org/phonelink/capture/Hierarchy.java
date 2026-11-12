package org.phonelink.capture;

import android.graphics.Rect;
import android.view.accessibility.AccessibilityNodeInfo;

/**
 * The accessibility tree as the XML {@code uiautomator dump} would have
 * written, so a harness that reads one reads the other.
 *
 * <p>One node per line, with the attributes in uiautomator's names:
 * {@code text}, {@code resource-id}, {@code class}, {@code package},
 * {@code content-desc}, the state flags and {@code bounds} as
 * {@code [left,top][right,bottom]}. Nothing here needs the view hierarchy: an
 * {@link AccessibilityNodeInfo} already carries all of it.
 */
final class Hierarchy {

    private Hierarchy() {
    }

    /**
     * The trees of several windows under one root, so a dialog that lives in a
     * window of its own is in the same document as the page behind it — which
     * is what a caller looking a button up needs.
     */
    static String of(java.util.List<AccessibilityNodeInfo> roots, int width, int height) {
        StringBuilder xml = new StringBuilder(4096);
        xml.append("<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>")
                .append("<hierarchy rotation=\"0\">\n");
        if (roots.size() == 1) {
            append(xml, roots.get(0), 0);
        } else {
            // More than one window: one wrapper so the document keeps a single
            // root, as uiautomator's own dumps do.
            xml.append("  <node");
            attr(xml, "index", "0");
            attr(xml, "text", "");
            attr(xml, "resource-id", "");
            attr(xml, "class", "android.widget.FrameLayout");
            attr(xml, "package", "");
            attr(xml, "content-desc", "");
            attr(xml, "bounds", "[0,0][" + width + "," + height + "]");
            xml.append(">\n");
            for (int i = 0; i < roots.size(); i++) {
                append(xml, roots.get(i), i);
            }
            xml.append("  </node>\n");
        }
        xml.append("</hierarchy>\n");
        return xml.toString();
    }

    private static void append(StringBuilder xml, AccessibilityNodeInfo node, int index) {
        Rect bounds = new Rect();
        node.getBoundsInScreen(bounds);
        xml.append("  <node");
        attr(xml, "index", Integer.toString(index));
        attr(xml, "text", text(node.getText()));
        attr(xml, "resource-id", text(node.getViewIdResourceName()));
        attr(xml, "class", text(node.getClassName()));
        attr(xml, "package", text(node.getPackageName()));
        attr(xml, "content-desc", text(node.getContentDescription()));
        flag(xml, "checkable", node.isCheckable());
        flag(xml, "checked", node.isChecked());
        flag(xml, "clickable", node.isClickable());
        flag(xml, "enabled", node.isEnabled());
        flag(xml, "focusable", node.isFocusable());
        flag(xml, "focused", node.isFocused());
        flag(xml, "scrollable", node.isScrollable());
        flag(xml, "long-clickable", node.isLongClickable());
        flag(xml, "password", node.isPassword());
        flag(xml, "selected", node.isSelected());
        attr(xml, "bounds", "[" + bounds.left + "," + bounds.top + "]"
                + "[" + bounds.right + "," + bounds.bottom + "]");
        int children = node.getChildCount();
        if (children == 0) {
            xml.append(" />\n");
            return;
        }
        xml.append(">\n");
        for (int i = 0; i < children; i++) {
            AccessibilityNodeInfo child = node.getChild(i);
            // Off-screen children of a scroll view are in the accessibility
            // tree too — with bounds outside the screen, or with the top below
            // the bottom — and a caller that looks a control up by id and taps
            // its centre would then tap something else entirely. `uiautomator
            // dump` leaves them out, so this does too.
            if (child != null && child.isVisibleToUser()) {
                append(xml, child, i);
            }
        }
        xml.append("  </node>\n");
    }

    private static void attr(StringBuilder xml, String name, String value) {
        xml.append(' ').append(name).append("=\"");
        escape(xml, value);
        xml.append('"');
    }

    private static void flag(StringBuilder xml, String name, boolean value) {
        attr(xml, name, value ? "true" : "false");
    }

    private static String text(CharSequence value) {
        return value == null ? "" : value.toString();
    }

    /** Attribute-safe: a quote in a label would otherwise end the attribute. */
    private static void escape(StringBuilder xml, String value) {
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '&':
                    xml.append("&amp;");
                    break;
                case '<':
                    xml.append("&lt;");
                    break;
                case '>':
                    xml.append("&gt;");
                    break;
                case '"':
                    xml.append("&quot;");
                    break;
                case '\n':
                    xml.append("&#10;");
                    break;
                case '\r':
                    xml.append("&#13;");
                    break;
                case '\t':
                    xml.append("&#9;");
                    break;
                default:
                    xml.append(c);
            }
        }
    }
}
