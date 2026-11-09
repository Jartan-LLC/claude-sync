"""Sphinx configuration. https://www.sphinx-doc.org/en/master/usage/configuration.html."""

project = "claude-sync"
author = "Jartan LLC"
project_copyright = "2026 Jartan LLC"

extensions = [
    "myst_parser",  # author docs in Markdown
]

myst_enable_extensions = ["colon_fence", "deflist", "tasklist"]
myst_heading_anchors = 3  # `#section` links, as GitHub resolves them

exclude_patterns = ["_build"]

html_theme = "furo"
