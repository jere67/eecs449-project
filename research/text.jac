"""Plain text from untrusted HTML, with length caps and the delimiters that mark it as data
(TDD §14, prompt injection).

Raw article and filing text reaches only the research sub-agents, which have no tools, and
always inside an untrusted_block: the prompt says that text inside one is data to analyze,
never instructions to follow. Downstream agents see only typed reports.
"""
import re;
import from html.parser { HTMLParser }

glob TRUNCATED: str = " [truncated]";
# How far back a cap looks for a space, so it does not end mid-word.
glob WORD_BREAK_WINDOW: int = 40;
glob _OPEN: str = "<untrusted-data";
glob _CLOSE: str = "</untrusted-data>";
glob _DELIMITER: re.Pattern[str] = re.compile(r"<\s*/?\s*untrusted-data", re.IGNORECASE);

"""The readable text of an HTML fragment: tags dropped, entities decoded, scripts and
styles removed, and one line per block element."""
def html_to_text(html: str) -> str {
    parser = _TextParser();
    parser.feed(html);
    parser.close();
    lines = [" ".join(line.split()) for line in "".join(parser.parts).splitlines()];
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip();
}

"""`text` cut to at most `limit` characters, at a word boundary when one is near, and marked
when cut."""
def cap(text: str, limit: int) -> str {
    if len(text) <= limit {
        return text;
    }
    room = limit - len(TRUNCATED);
    cut = text[:room];
    space = cut.rfind(" ");
    if space >= room - WORD_BREAK_WINDOW {
        cut = cut[:space];
    }
    return cut.rstrip() + TRUNCATED;
}

"""`text` wrapped as untrusted data, labeled with `kind` and attributes such as its URL.
Any delimiter inside the text is defused, so the text cannot end the block early."""
def untrusted_block(kind: str, text: str, attributes: dict[str, str] | None = None) -> str {
    labels = [f'kind="{_attribute(kind)}"'] + [f'{name}="{_attribute(value)}"' for (name, value) in (attributes or {}).items()];
    body = _DELIMITER.sub("[delimiter removed]", text);
    return f"{_OPEN} {' '.join(labels)}>\n{body}\n{_CLOSE}";
}

def _attribute(value: str) -> str {
    return " ".join(_DELIMITER.sub("", value).replace('"', "'").replace(">", " ").split());
}

glob _BLOCKS: set[str] = {
    "p", "div", "br", "li", "ul", "ol", "tr", "table", "h1", "h2", "h3", "h4", "h5", "h6",
    "blockquote", "pre", "section", "article", "header", "footer"
};

class _TextParser(HTMLParser) {
    def init(self: _TextParser) {
        super.init(convert_charrefs=True);
        self.parts: list[str] = [];
        self._hidden = 0;
    }

    override def handle_starttag(self: _TextParser, tag: str, _attrs: list[tuple[str, str | None]]) {
        if tag in ("script", "style") {
            self._hidden += 1;
        } elif tag in _BLOCKS {
            self.parts.append("\n");
        } elif tag in ("td", "th") {
            self.parts.append(" ");
        }
    }

    override def handle_endtag(self: _TextParser, tag: str) {
        if tag in ("script", "style") {
            self._hidden = max(0, self._hidden - 1);
        } elif tag in _BLOCKS {
            self.parts.append("\n");
        }
    }

    override def handle_data(self: _TextParser, data: str) {
        if not self._hidden {
            self.parts.append(data);
        }
    }
}
