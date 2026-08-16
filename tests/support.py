from log_migration.normalize import NormalizedPost, NormalizationResult


def normalized_result_with_external_urls(
    *url_groups: tuple[str, ...],
) -> NormalizationResult:
    posts = tuple(
        NormalizedPost(
            id=f"post-{chr(ord('a') + index)}",
            frontmatter={
                "title": f"Post {index}",
                "source_project": "memo",
                "created_at": None,
                "updated_at": None,
                "published_at": None,
                "visibility": "public",
            },
            body="",
            links=(),
            asset_references=(),
            external_urls=tuple(urls),
            issues=(),
        )
        for index, urls in enumerate(url_groups)
    )
    return NormalizationResult(posts=posts, mapping={}, issues=())
