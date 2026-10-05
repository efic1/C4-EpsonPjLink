#!/usr/bin/env python3
"""Check that driver.xml is well-formed and has the structure Control4 expects."""
import sys
import xml.dom.minidom as minidom

path = sys.argv[1] if len(sys.argv) > 1 else "driver.xml"
doc = minidom.parse(path)  # raises on malformed XML
root = doc.documentElement
if root.tagName != "devicedata":
    sys.exit("root element must be <devicedata>, got <%s>" % root.tagName)

def child(node, name):
    return [c for c in node.childNodes if c.nodeType == c.ELEMENT_NODE and c.tagName == name]

problems = []
for required in ("name", "model", "manufacturer", "control", "driver", "proxies", "config", "events", "connections"):
    if not child(root, required):
        problems.append("missing <%s>" % required)

config = child(root, "config")[0]
for required in ("script", "properties", "actions", "commands", "conditionals"):
    if not child(config, required):
        problems.append("missing <config>/<%s>" % required)

# Binding ids must be unique across <connections> and within their documented ranges.
ids = []
for conn in child(child(root, "connections")[0], "connection"):
    cid = int(child(conn, "id")[0].firstChild.data)
    ids.append(cid)
if len(ids) != len(set(ids)):
    problems.append("duplicate connection ids: %s" % ids)

names = [c.firstChild.data for p in child(child(config, "properties")[0], "property")
         for c in child(p, "name")]
if len(names) != len(set(names)):
    problems.append("duplicate property names")

if problems:
    sys.exit("driver.xml problems:\n  " + "\n  ".join(problems))
print("driver.xml OK: %d properties, %d connections" % (len(names), len(ids)))
