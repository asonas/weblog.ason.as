from log_migration.authoring.links import extract_wiki_links, replace_wiki_links


def test_extract_wiki_links_trims_names_and_ignores_code_fences():
    body = "[[ page-a ]]\n\n```md\n[[ignored]]\n```\n\n[[page-b]]"

    links = extract_wiki_links(body)

    assert tuple(link.name for link in links) == ("page-a", "page-b")


def test_replace_wiki_links_does_not_replace_prefix_matches():
    assert replace_wiki_links("[[page-a]] [[page-ab]]", "page-a", "page-b") == "[[page-b]] [[page-ab]]"
