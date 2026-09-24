"""OPML import/export for podcast subscriptions.

OPML (Outline Processor Markup Language) is the interchange format every
podcast app reads and writes. Supporting it makes backups and migration
between apps trivial — export a file, import it somewhere else.

Spec summary for podcast OPML:
    <opml version="2.0">
      <head>
        <title>Subscriptions</title>
      </head>
      <body>
        <outline text="Show Name" title="Show Name"
                 type="rss"
                 xmlUrl="https://example.com/feed.xml"
                 htmlUrl="https://example.com" />
        ...
      </body>
    </opml>

We only care about outlines with type="rss" and xmlUrl — the rest is
cosmetic / for podcast-app UIs.
"""

import xml.etree.ElementTree as ET
from html import escape


def build_opml(feeds):
    """Serialize a list of feed dicts into an OPML 2.0 XML string.

    Each feed dict should have: feed_url, title, author (optional),
    link (optional for htmlUrl).
    """
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<opml version="2.0">',
        '  <head>',
        '    <title>NASRadio Podcast Subscriptions</title>',
        '  </head>',
        '  <body>',
    ]
    for feed in feeds:
        title = escape(feed.get("title") or "Untitled")
        xml_url = escape(feed.get("feed_url") or "")
        html_url = escape(feed.get("link") or "")
        if not xml_url:
            continue
        attrs = [
            f'type="rss"',
            f'text="{title}"',
            f'title="{title}"',
            f'xmlUrl="{xml_url}"',
        ]
        if html_url:
            attrs.append(f'htmlUrl="{html_url}"')
        lines.append(f'    <outline {" ".join(attrs)} />')
    lines.append('  </body>')
    lines.append('</opml>')
    return "\n".join(lines) + "\n"


def parse_opml(opml_text):
    """Extract {title, feed_url} pairs from OPML XML.

    Returns an empty list if the XML is malformed or contains no
    rss-type outlines. Doesn't raise — the caller is expected to
    surface "imported N subscriptions" either way.
    """
    feeds = []
    try:
        root = ET.fromstring(opml_text)
    except ET.ParseError:
        return feeds

    # Outlines can be nested (folders). Walk recursively — podcast
    # clients vary in whether they use folder grouping.
    def walk(node):
        for outline in node.findall("outline"):
            feed_type = (outline.get("type") or "").lower()
            xml_url = outline.get("xmlUrl") or outline.get("xmlurl")
            if feed_type == "rss" and xml_url:
                feeds.append({
                    "title": outline.get("text") or outline.get("title") or xml_url,
                    "feed_url": xml_url,
                })
            # Recurse into folder-style outlines
            walk(outline)

    body = root.find("body")
    if body is not None:
        walk(body)
    return feeds
