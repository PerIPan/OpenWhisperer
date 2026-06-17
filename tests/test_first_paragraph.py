import subprocess
from pathlib import Path

HOOK = Path(__file__).resolve().parents[1] / "hooks" / "first-paragraph.sh"


def first_para(text: str) -> str:
    out = subprocess.run([str(HOOK)], input=text, capture_output=True, text=True)
    return out.stdout


def test_single_paragraph_plain():
    assert first_para("Fixed it. Tests pass now.\n") == "Fixed it. Tests pass now."


def test_stops_at_blank_line():
    assert first_para("First line stays.\n\nSecond paragraph dropped.\n") == "First line stays."


def test_skips_leading_code_fence():
    md = "```swift\nlet x = 1\n```\n\nThe real summary sentence.\n"
    assert first_para(md) == "The real summary sentence."


def test_skips_leading_heading():
    assert first_para("## Result\nDone and verified.\n") == "Done and verified."


def test_strips_inline_markdown_and_links():
    md = "Updated **auth** in `login.swift` see [docs](http://x.io/y) now.\n"
    assert first_para(md) == "Updated auth in login.swift see docs now."


def test_empty_when_no_prose():
    assert first_para("```\ncode only\n```\n") == ""


def test_caps_long_paragraph_at_sentence_boundary():
    long = ("Sentence one is here. " * 40).strip() + "\n"
    out = first_para(long)
    assert len(out) <= 600
    assert out.endswith(".")
