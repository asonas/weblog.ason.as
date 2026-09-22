import { useEffect, useState } from "react";

export function CoverPhoto({
  url,
  hero = false,
}: {
  url: string;
  hero?: boolean;
}) {
  const [failedUrl, setFailedUrl] = useState<string | null>(null);
  const [isMobile, setIsMobile] = useState(
    () => hero && window.matchMedia("(max-width: 600px)").matches,
  );
  useEffect(() => {
    if (!hero) return;
    const media = window.matchMedia("(max-width: 600px)");
    const update = () => setIsMobile(media.matches);
    update();
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, [hero]);
  const preview = url.startsWith("/assets/") && failedUrl !== url;
  const path = url.slice("/assets/".length);
  const small = `/assets/previews/640/${path}.webp`;
  const large = `/assets/previews/1280/${path}.webp`;
  const image = (
    <img
      className={hero ? undefined : "cf-photo"}
      src={preview && !hero ? small : url}
      alt=""
      loading={hero ? "eager" : "lazy"}
      fetchPriority={hero ? "high" : undefined}
      decoding="async"
      onError={() => setFailedUrl(url)}
    />
  );
  if (!hero) return image;

  return (
    // Responsive source failures can omit error events on an already loaded image.
    <picture
      className="cover-journal__photo"
      key={isMobile ? "mobile" : "desktop"}
    >
      {preview && (
        <source
          media="(max-width: 600px)"
          srcSet={`${small} 640w, ${large} 1280w`}
          sizes="100vw"
        />
      )}
      {image}
    </picture>
  );
}
