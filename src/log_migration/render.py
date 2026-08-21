import html
import json
import shutil
from collections import defaultdict
from datetime import date, timedelta
from pathlib import Path
from typing import Iterable, Mapping

from markdown_it import MarkdownIt

from .asset_manifest import classify_url, stable_url_asset_id
from .index import LinkIndex, stable_asset_id
from .normalize import NormalizedPost, NormalizationResult
from .url_metadata import load_url_metadata


_MARKDOWN = MarkdownIt("commonmark", {"breaks": True, "html": False})
_TEMPLATE = Path(__file__).parent / "templates" / "weblog.html"
_CARD_TEMPLATE = Path(__file__).parent / "templates" / "cards.html"
_CARD_SCRIPT = Path(__file__).parent / "static" / "cards.js"
_CARD_DATA_URL = "/static/cards-data.json"
_CARD_DEPTHS = (0, 1, 2, 3)
_RANGE_DAYS: dict[str, int | None] = {
    "1d": 1,
    "7d": 7,
    "30d": 30,
    "100d": 100,
    "all": None,
}
_RANGE_LABELS = {
    "1d": "1日",
    "7d": "7日",
    "30d": "30日",
    "100d": "100日",
    "all": "全期間",
}


def render_site(
    normalized: NormalizationResult,
    index: LinkIndex,
    output_dir: Path,
    *,
    url_metadata_path: Path | None = None,
    asset_dir: Path | None = None,
) -> None:
    """Render the public normalized snapshot as a small static website."""

    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    public_posts = tuple(_public_posts(normalized.posts))
    posts_by_id = {post.id: post for post in public_posts}
    assets = _assets(public_posts)
    url_metadata = load_url_metadata(url_metadata_path)
    image_paths = _copy_url_images(output_dir, asset_dir, url_metadata)
    _write_card_script(output_dir)
    _write_card_data(output_dir, normalized, url_metadata, image_paths)

    dated_posts: dict[str, list[NormalizedPost]] = defaultdict(list)
    undated_posts: list[NormalizedPost] = []
    for post in public_posts:
        date_text = _date_text(post)
        if date_text is None:
            undated_posts.append(post)
        else:
            dated_posts[date_text].append(post)

    for date_text, posts in sorted(dated_posts.items()):
        _write_page(
            output_dir / date_text / "index.html",
            title=date_text,
            content=_render_weblog(
                posts,
                index,
                posts_by_id,
                assets,
                url_metadata,
                image_paths,
            ),
        )

    _write_page(
        output_dir / "undated" / "index.html",
        title="日時なし",
        content=_render_weblog(
            undated_posts,
            index,
            posts_by_id,
            assets,
            url_metadata,
            image_paths,
        ),
    )

    _write_page(
        output_dir / "index.html",
        title="log.ason.as",
        content=_render_index(dated_posts, undated_posts),
    )

    for post in public_posts:
        _write_page(
            output_dir / "posts" / post.id / "index.html",
            title=str(post.frontmatter["title"]),
            content=_render_post_page(
                post,
                index,
                posts_by_id,
                assets,
                url_metadata,
                image_paths,
            ),
        )
        card_page = output_dir / "posts" / post.id / "cards" / "index.html"
        card_page.parent.mkdir(parents=True, exist_ok=True)
        card_page.write_text(
            render_cards(
                normalized,
                index,
                root_id=post.id,
                url_metadata=url_metadata,
                image_paths=image_paths,
            ),
            encoding="utf-8",
        )

    for asset_id, source_path in sorted(assets.items()):
        _write_page(
            output_dir / "assets" / asset_id / "index.html",
            title=source_path,
            content=_render_asset_page(
                asset_id,
                source_path,
                index,
                posts_by_id,
            ),
        )


def _public_posts(posts: Iterable[NormalizedPost]) -> Iterable[NormalizedPost]:
    return (
        post
        for post in posts
        if post.frontmatter.get("visibility") == "public"
    )


def _assets(posts: Iterable[NormalizedPost]) -> dict[str, str]:
    assets: dict[str, str] = {}
    for post in posts:
        for source_path in post.asset_references:
            assets[stable_asset_id(source_path)] = source_path
        for url in post.external_urls:
            assets[stable_url_asset_id(url)] = url
    return assets


def _date_text(post: NormalizedPost) -> str | None:
    created_at = post.frontmatter.get("created_at")
    if created_at is None:
        return None
    return str(created_at)[:10]


def _render_index(
    dated_posts: dict[str, list[NormalizedPost]],
    undated_posts: list[NormalizedPost],
) -> str:
    links = [
        f'<li><a href="/{html.escape(date_text)}/">{html.escape(date_text)}</a>'
        f" ({len(posts)}件)</li>"
        for date_text, posts in sorted(dated_posts.items(), reverse=True)
    ]
    if undated_posts:
        links.append(
            f'<li><a href="/undated/">日時なし</a> ({len(undated_posts)}件)</li>'
        )
    if not links:
        return '<p class="empty-state">公開記事はありません。</p>'
    return '<ul class="date-list">' + "".join(links) + "</ul>"


def _render_weblog(
    posts: Iterable[NormalizedPost],
    index: LinkIndex,
    posts_by_id: dict[str, NormalizedPost],
    assets: dict[str, str],
    url_metadata: Mapping[str, Mapping[str, object]],
    image_paths: Mapping[str, str],
) -> str:
    ordered_posts = sorted(posts, key=_post_sort_key)
    if not ordered_posts:
        return '<p class="empty-state">このページには公開記事がありません。</p>'

    cards = [
        _render_post_card(
            post,
            index=index,
            posts_by_id=posts_by_id,
            assets=assets,
            url_metadata=url_metadata,
            image_paths=image_paths,
            expanded=position == 0,
        )
        for position, post in enumerate(ordered_posts)
    ]
    return '<section class="post-stream">' + "".join(cards) + "</section>"


def _post_sort_key(post: NormalizedPost) -> tuple[str, str, str]:
    created_at = post.frontmatter.get("created_at")
    return (
        str(created_at) if created_at is not None else "9999-99-99T99:99:99+00:00",
        str(post.frontmatter["title"]),
        post.id,
    )


def _render_post_page(
    post: NormalizedPost,
    index: LinkIndex,
    posts_by_id: dict[str, NormalizedPost],
    assets: dict[str, str],
    url_metadata: Mapping[str, Mapping[str, object]],
    image_paths: Mapping[str, str],
) -> str:
    card = _render_post_card(
        post,
        index=index,
        posts_by_id=posts_by_id,
        assets=assets,
        url_metadata=url_metadata,
        image_paths=image_paths,
        expanded=True,
    )
    backlinks = _render_post_backlinks(post.id, index, posts_by_id)
    card_link = (
        f'<p class="post-mode-link"><a href="/posts/{html.escape(post.id, quote=True)}/cards/">'
        "カードモードで見る</a></p>"
    )
    return card_link + card + backlinks


def render_cards(
    normalized: NormalizationResult,
    index: LinkIndex,
    *,
    root_id: str,
    range_name: str = "all",
    depth: int = 1,
    url_metadata: Mapping[str, Mapping[str, object]] | None = None,
    image_paths: Mapping[str, str] | None = None,
) -> str:
    """Render an article-rooted, deduplicated card exploration."""

    if range_name not in _RANGE_DAYS:
        allowed = ", ".join(_RANGE_DAYS)
        raise ValueError(f"unknown range_name {range_name!r}; expected one of {allowed}")
    if depth < 0:
        raise ValueError("depth must be zero or greater")

    public_posts = tuple(_public_posts(normalized.posts))
    posts_by_id = {post.id: post for post in public_posts}
    assets = _assets(public_posts)
    url_metadata = url_metadata or {}
    image_paths = image_paths or {}
    root = posts_by_id.get(root_id)
    if root is None:
        raise ValueError(f"root post is not public or does not exist: {root_id}")

    start_date, end_date = _range_bounds(root, _RANGE_DAYS[range_name])
    neighbor_ids = index.neighbors(
        root_id,
        direction="both",
        depth=depth,
        start_date=start_date,
        end_date=end_date,
    )
    post_ids = [node_id for node_id in neighbor_ids if node_id in posts_by_id]
    asset_ids = [node_id for node_id in neighbor_ids if node_id in assets]
    post_ids.sort(key=lambda node_id: _post_sort_key(posts_by_id[node_id]))
    asset_ids.sort(key=lambda node_id: assets[node_id])

    cards = [
        _render_exploration_post_card(
            root,
            root_id=root_id,
            index=index,
            posts_by_id=posts_by_id,
            expanded=True,
        )
    ]
    cards.extend(
        _render_exploration_post_card(
            posts_by_id[post_id],
            root_id=root_id,
            index=index,
            posts_by_id=posts_by_id,
            expanded=False,
        )
        for post_id in post_ids
    )
    cards.extend(
        _render_exploration_asset_card(
            asset_id,
            assets[asset_id],
            root_id=root_id,
            index=index,
            posts_by_id=posts_by_id,
            url_metadata=url_metadata,
            image_paths=image_paths,
        )
        for asset_id in asset_ids
    )

    controls = _render_range_controls(range_name, root_id, depth)
    content = (
        f'<section class="card-explorer" data-root-id="{html.escape(root_id, quote=True)}" '
        f'data-range="{html.escape(range_name, quote=True)}" data-depth="{depth}" '
        f'data-card-data-url="{_CARD_DATA_URL}">'
        f"{controls}"
        f'<div class="card-canvas">{"".join(cards)}</div>'
        '<p class="card-status" role="status" aria-live="polite"></p>'
        '<noscript><p>探索範囲とリンク深度の変更にはJavaScriptが必要です。</p></noscript>'
        "</section>"
    )
    return _render_card_document(
        title=f'{root.frontmatter["title"]} — カード',
        content=content,
    )


def _range_bounds(
    root: NormalizedPost,
    days: int | None,
) -> tuple[date | None, date | None]:
    if days is None:
        return None, None
    created_at = root.frontmatter.get("created_at")
    if created_at is None:
        return None, None
    root_date = date.fromisoformat(str(created_at)[:10])
    delta = timedelta(days=days)
    return root_date - delta, root_date + delta


def _render_range_controls(range_name: str, root_id: str, depth: int) -> str:
    options = "".join(
        _render_range_option(name, label, range_name, root_id, depth)
        for name, label in _RANGE_LABELS.items()
    )
    depth_options = "".join(
        _render_depth_option(value, root_id, range_name, depth)
        for value in _CARD_DEPTHS
    )
    return (
        '<nav class="card-controls" aria-label="カードの探索範囲">'
        f"{options}"
        f'<span class="depth-options" aria-label="リンク深度">{depth_options}</span>'
        "</nav>"
    )


def _render_range_option(
    name: str,
    label: str,
    selected_name: str,
    root_id: str,
    depth: int,
) -> str:
    selected = " is-selected" if name == selected_name else ""
    current = ' aria-current="page"' if name == selected_name else ""
    escaped_root_id = html.escape(root_id, quote=True)
    return (
        f'<a class="range-option{selected}" data-range-option="{name}"{current} '
        f'href="?root={escaped_root_id}&amp;range={name}&amp;depth={depth}">'
        f"{label}</a>"
    )


def _render_depth_option(
    value: int,
    root_id: str,
    range_name: str,
    selected_depth: int,
) -> str:
    selected = " is-selected" if value == selected_depth else ""
    current = ' aria-current="page"' if value == selected_depth else ""
    escaped_root_id = html.escape(root_id, quote=True)
    return (
        f'<a class="depth-option{selected}" data-depth-option="{value}"{current} '
        f'href="?root={escaped_root_id}&amp;range={range_name}&amp;depth={value}">'
        f"深さ{value}</a>"
    )


def _render_exploration_post_card(
    post: NormalizedPost,
    *,
    root_id: str,
    index: LinkIndex,
    posts_by_id: dict[str, NormalizedPost],
    expanded: bool,
) -> str:
    post_id = html.escape(post.id, quote=True)
    title = html.escape(str(post.frontmatter["title"]))
    is_root = post.id == root_id
    card_classes = ["exploration-card", "post-card"]
    card_classes.append("card--root" if is_root else "card--compact")
    body_class = "post-body" if expanded else "post-body post-body--compact"
    relation = "起点" if is_root else _relation_label(root_id, post.id, index)
    created_at = post.frontmatter.get("created_at")
    time_html = ""
    if created_at is not None:
        value = html.escape(str(created_at), quote=True)
        time_html = f'<time datetime="{value}">{value[:10]}</time>'
    toggle = "" if is_root else '<button type="button" data-card-toggle aria-expanded="false">展開</button>'
    return (
        f'<article class="{" ".join(card_classes)}" data-post-id="{post_id}">'
        f'<p class="card-relation">{html.escape(relation)}</p>'
        f'<header class="post-card__header"><h2><a href="/posts/{post_id}/">{title}</a></h2>'
        f"{time_html}{toggle}</header>"
        f'<div class="{body_class}">{_MARKDOWN.render(post.body)}</div>'
        "</article>"
    )


def _render_exploration_asset_card(
    asset_id: str,
    source_path: str,
    *,
    root_id: str,
    index: LinkIndex,
    posts_by_id: dict[str, NormalizedPost],
    url_metadata: Mapping[str, Mapping[str, object]],
    image_paths: Mapping[str, str],
) -> str:
    references = [
        posts_by_id[post_id]
        for post_id in index.find_backlinks(asset_id)
        if post_id in posts_by_id
    ]
    visible_references = references[:3]
    remaining = len(references) - len(visible_references)
    links = "".join(
        f'<li><a href="/posts/{html.escape(post.id, quote=True)}/">'
        f'{html.escape(str(post.frontmatter["title"]))}</a></li>'
        for post in visible_references
    )
    if remaining:
        links += f"<li>ほか{remaining}件</li>"
    reference_html = f"<ul>{links}</ul>" if links else "<p>参照元なし</p>"
    kind = (
        classify_url(source_path)
        if source_path.startswith(("http://", "https://"))
        else "asset"
    )
    metadata = url_metadata.get(asset_id)
    image_path = image_paths.get(asset_id)
    image_class = " asset-card--with-image" if image_path else ""
    return (
        f'<article class="exploration-card asset-card{image_class} card--compact" '
        f'{_asset_background_style(image_path)} '
        f'data-asset-id="{html.escape(asset_id, quote=True)}">'
        f'<p class="card-relation">{html.escape(_relation_label(root_id, asset_id, index))}</p>'
        f'<a href="/assets/{html.escape(asset_id, quote=True)}/">'
        f'{_render_asset_card_content(source_path, kind, metadata)}</a>'
        f'<div class="asset-card__references"><span>参照元</span>{reference_html}</div>'
        "</article>"
    )


def _relation_label(first_id: str, second_id: str, index: LinkIndex) -> str:
    directions = index.directions_between(first_id, second_id)
    if directions == ("incoming", "outgoing"):
        return "相互参照"
    if "outgoing" in directions:
        return "参照先"
    if "incoming" in directions:
        return "逆リンク"
    return "関連"


def _render_card_document(*, title: str, content: str) -> str:
    document = _CARD_TEMPLATE.read_text(encoding="utf-8")
    document = document.replace("{{title}}", html.escape(title))
    document = document.replace("{{content}}", content)
    return document


def _copy_url_images(
    output_dir: Path,
    asset_dir: Path | None,
    url_metadata: Mapping[str, Mapping[str, object]],
) -> dict[str, str]:
    if asset_dir is None:
        return {}

    asset_dir = Path(asset_dir)
    asset_root = asset_dir.resolve()
    image_paths: dict[str, str] = {}
    for asset_id, metadata in url_metadata.items():
        image = metadata.get("image")
        if not isinstance(image, Mapping):
            continue
        local_path = image.get("local_path")
        if not isinstance(local_path, str) or Path(local_path).name != local_path:
            continue
        source = asset_dir / local_path
        try:
            if source.resolve().parent != asset_root or not source.is_file():
                continue
        except OSError:
            continue
        target = output_dir / "assets" / asset_id / local_path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        image_paths[asset_id] = f"/assets/{asset_id}/{local_path}"
    return image_paths


def _write_card_script(output_dir: Path) -> None:
    target = output_dir / "static" / "cards.js"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(_CARD_SCRIPT.read_text(encoding="utf-8"), encoding="utf-8")


def _write_card_data(
    output_dir: Path,
    normalized: NormalizationResult,
    url_metadata: Mapping[str, Mapping[str, object]],
    image_paths: Mapping[str, str],
) -> None:
    target = output_dir / "static" / "cards-data.json"
    target.write_text(
        json.dumps(
            _card_data(normalized, url_metadata, image_paths),
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n",
        encoding="utf-8",
    )


def _card_data(
    normalized: NormalizationResult,
    url_metadata: Mapping[str, Mapping[str, object]],
    image_paths: Mapping[str, str],
) -> dict[str, object]:
    public_posts = tuple(_public_posts(normalized.posts))
    posts_by_id = {post.id: post for post in public_posts}
    assets = _assets(public_posts)
    edges = _card_edges(normalized, public_posts, posts_by_id, assets)

    posts = [
        {
            "body_html": _MARKDOWN.render(post.body),
            "created_at": post.frontmatter.get("created_at"),
            "id": post.id,
            "title": str(post.frontmatter["title"]),
        }
        for post in sorted(public_posts, key=_post_sort_key)
    ]
    assets_data = []
    for asset_id, source_path in sorted(assets.items(), key=lambda item: item[1]):
        metadata = url_metadata.get(asset_id)
        asset_data: dict[str, object] = {
            "id": asset_id,
            "kind": (
                classify_url(source_path)
                if source_path.startswith(("http://", "https://"))
                else "asset"
            ),
            "references": [
                source_id
                for source_id, target_id in edges
                if target_id == asset_id
            ],
            "source_path": source_path,
        }
        if metadata is not None:
            asset_data.update(
                {
                    "description": _metadata_text(metadata, "description"),
                    "domain": _metadata_text(metadata, "domain"),
                    "title": _metadata_text(metadata, "title"),
                }
            )
        if asset_id in image_paths:
            asset_data["image_path"] = image_paths[asset_id]
        assets_data.append(asset_data)
    return {
        "assets": assets_data,
        "edges": [
            {"source": source_id, "target": target_id}
            for source_id, target_id in edges
        ],
        "posts": posts,
        "version": 1,
    }


def _card_edges(
    normalized: NormalizationResult,
    public_posts: Iterable[NormalizedPost],
    posts_by_id: dict[str, NormalizedPost],
    assets: dict[str, str],
) -> list[tuple[str, str]]:
    edges: set[tuple[str, str]] = set()
    for post in public_posts:
        source_project = str(post.frontmatter["source_project"])
        for target_title in post.links:
            target_id = normalized.mapping.get(f"{source_project}\x00{target_title}")
            if target_id in posts_by_id:
                edges.add((post.id, target_id))
        for source_path in post.asset_references:
            asset_id = stable_asset_id(source_path)
            if asset_id in assets:
                edges.add((post.id, asset_id))
        for url in post.external_urls:
            asset_id = stable_url_asset_id(url)
            if asset_id in assets:
                edges.add((post.id, asset_id))
    return sorted(edges)


def _render_post_card(
    post: NormalizedPost,
    *,
    index: LinkIndex,
    posts_by_id: dict[str, NormalizedPost],
    assets: dict[str, str],
    url_metadata: Mapping[str, Mapping[str, object]],
    image_paths: Mapping[str, str],
    expanded: bool,
) -> str:
    title = html.escape(str(post.frontmatter["title"]))
    post_id = html.escape(post.id, quote=True)
    created_at = post.frontmatter.get("created_at")
    time_html = ""
    if created_at is not None:
        time_value = html.escape(str(created_at), quote=True)
        time_html = f'<time datetime="{time_value}">{time_value[:10]}</time>'

    card_class = "card--expanded" if expanded else "card--compact"
    body_class = "post-body" if expanded else "post-body post-body--compact"
    body_html = _MARKDOWN.render(post.body)
    asset_ids = [
        stable_asset_id(path) for path in post.asset_references
    ] + [
        stable_url_asset_id(url) for url in post.external_urls
    ]
    asset_html = "".join(
        _render_asset_card(
            asset_id,
            assets[asset_id],
            index,
            posts_by_id,
            url_metadata.get(asset_id),
            image_paths.get(asset_id),
        )
        for asset_id in asset_ids
        if asset_id in assets
    )
    return (
        f'<article class="post-card {card_class}" data-post-id="{post_id}">'
        f'<header class="post-card__header">'
        f'<h2><a href="/posts/{post_id}/">{title}</a></h2>{time_html}'
        f"</header>"
        f'<div class="{body_class}">{body_html}</div>'
        f'<div class="post-assets">{asset_html}</div>'
        "</article>"
    )


def _render_asset_card(
    asset_id: str,
    source_path: str,
    index: LinkIndex,
    posts_by_id: dict[str, NormalizedPost],
    metadata: Mapping[str, object] | None,
    image_path: str | None,
) -> str:
    escaped_id = html.escape(asset_id, quote=True)
    kind = (
        classify_url(source_path)
        if source_path.startswith(("http://", "https://"))
        else "asset"
    )
    backlinks = [
        posts_by_id[post_id]
        for post_id in index.find_backlinks(asset_id)
        if post_id in posts_by_id
    ]
    used_by = ""
    if backlinks:
        links = "".join(
            f'<a href="/posts/{html.escape(post.id, quote=True)}/">'
            f'{html.escape(str(post.frontmatter["title"]))}</a>'
            for post in backlinks
        )
        used_by = f'<span class="asset-card__backlinks">参照: {links}</span>'
    image_class = " asset-card--with-image" if image_path else ""
    return (
        f'<article class="asset-card{image_class} card--compact" '
        f'{_asset_background_style(image_path)} '
        f'data-asset-id="{escaped_id}">'
        f'<a href="/assets/{escaped_id}/">'
        f'{_render_asset_card_content(source_path, kind, metadata)}'
        "</a>"
        f"{used_by}"
        "</article>"
    )


def _render_asset_card_content(
    source_path: str,
    kind: str,
    metadata: Mapping[str, object] | None,
) -> str:
    title = _metadata_text(metadata, "title") if metadata is not None else None
    domain = _metadata_text(metadata, "domain") if metadata is not None else None
    description = (
        _metadata_text(metadata, "description") if metadata is not None else None
    )
    name = title or domain or source_path
    domain_html = ""
    if domain and domain != name:
        domain_html = f'<span class="asset-card__domain">{html.escape(domain)}</span>'
    url_html = ""
    if metadata is not None:
        url_html = f'<span class="asset-card__url">{html.escape(source_path)}</span>'
    description_html = ""
    if description:
        description_html = (
            f'<span class="asset-card__description">{html.escape(description)}</span>'
        )
    return (
        f'<span class="asset-card__kind">{html.escape(kind)}</span>'
        f'<span class="asset-card__name">{html.escape(name)}</span>'
        f"{domain_html}{url_html}{description_html}"
    )


def _metadata_text(
    metadata: Mapping[str, object] | None,
    key: str,
) -> str | None:
    if metadata is None:
        return None
    value = metadata.get(key)
    return value if isinstance(value, str) and value else None


def _asset_background_style(image_path: str | None) -> str:
    if not image_path:
        return ""
    escaped_path = html.escape(image_path, quote=True)
    return f'style="--asset-background-image: url(\'{escaped_path}\')"'


def _render_post_backlinks(
    post_id: str,
    index: LinkIndex,
    posts_by_id: dict[str, NormalizedPost],
) -> str:
    backlinks = [
        posts_by_id[source_id]
        for source_id in index.find_backlinks(post_id)
        if source_id in posts_by_id
    ]
    if not backlinks:
        return ""
    links = "".join(
        f'<li><a href="/posts/{html.escape(post.id, quote=True)}/">'
        f'{html.escape(str(post.frontmatter["title"]))}</a></li>'
        for post in backlinks
    )
    return f'<aside class="backlinks"><h2>参照している記事</h2><ul>{links}</ul></aside>'


def _render_asset_page(
    asset_id: str,
    source_path: str,
    index: LinkIndex,
    posts_by_id: dict[str, NormalizedPost],
) -> str:
    escaped_path = html.escape(source_path)
    backlinks = _render_post_backlinks(asset_id, index, posts_by_id)
    return (
        f'<article class="asset-page" data-asset-id="{html.escape(asset_id, quote=True)}">'
        f'<p class="asset-page__placeholder">{escaped_path}</p>'
        "</article>"
        f"{backlinks}"
    )


def _write_page(path: Path, *, title: str, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    document = _TEMPLATE.read_text(encoding="utf-8")
    document = document.replace("{{title}}", html.escape(title))
    document = document.replace("{{content}}", content)
    path.write_text(document, encoding="utf-8")
