# frozen_string_literal: true

require "cgi"
require "digest"

require_relative "cover_image"
require_relative "phrase_segmenter"

module WeblogAuthoring
  # The image an article without a cover shows when it is shared: its title on the site's paper.
  module OgImage
    WIDTH = 1200
    HEIGHT = 630
    # Bump when the font or the layout changes, so pages point at a new URL instead of a cached old image.
    TEMPLATE = "v1"
    HOME_KEY = "assets/og/home-#{TEMPLATE}.png".freeze
    CACHE_CONTROL = "public, max-age=31536000, immutable"

    module_function

    def key(title)
      "assets/og/#{Digest::SHA256.hexdigest("#{TEMPLATE}\0#{title}")[0, 32]}.png"
    end

    # Chooses the font size and the line breaks for a title. It never measures text itself:
    # `measure.call(text, size)` returns a width in pixels.
    class Layout
      SIZES = [120, 96, 80, 68, 58, 50].freeze
      BOX_WIDTH = 1040
      BOX_HEIGHT = 400
      LINE_HEIGHT = 1.3
      ELLIPSIS = "…"
      MAX_CHARACTERS = 400
      # The font has no emoji and no fallback font is installed, so each would be drawn as a box with its code point.
      EMOJI = /[\p{Extended_Pictographic}\p{Emoji_Modifier}\u{FE0F}\u{200D}\u{20E3}]/
      # Pango rejects markup that contains control characters.
      CONTROL = /[\p{Cntrl}&&[^ ]]/
      # Line candidates are sized by adding up unit widths, which can differ from the width of the line drawn as a whole.
      # When a chosen line turns out too wide, the layout is redone against the next narrower limit.
      LIMITS = [1.0, 0.95, 0.9, 0.85].map { |ratio| (BOX_WIDTH * ratio).round }.freeze

      Result = Data.define(:size, :lines)

      def initialize(measure:, segmenter: PhraseSegmenter.new)
        @widths = {}
        @measure = ->(text, size) { @widths[[text, size]] ||= measure.call(text, size) }
        @segmenter = segmenter
      end

      def call(title)
        # One Layout serves every title a worker draws. Widths are only reused within a title.
        @widths.clear
        # No size shows more than a few hundred characters, and layout work grows with the length.
        text = title.to_s.gsub(/\s+/, " ").gsub(EMOJI, "").gsub(CONTROL, "").strip[0, MAX_CHARACTERS]
        return Result.new(size: SIZES.first, lines: []) if text.empty?

        SIZES.each do |size|
          lines = fitted(size) { |limit| lines_within(text, size, limit, balance: true) }
          return Result.new(size:, lines:) if lines && lines.length <= capacity(size)
        end
        size = SIZES.last
        lines = fitted(size) { |limit| lines_within(text, size, limit, balance: false).first(capacity(size)) }
        lines ||= lines_within(text, size, LIMITS.last, balance: false).first(capacity(size)).map { |line| clip(line, size) }
        Result.new(size:, lines: truncate(lines, size))
      end

      private

      def capacity(size) = (BOX_HEIGHT / (size * LINE_HEIGHT)).floor

      # The first layout whose lines all fit when measured whole, or nil when none does at this size.
      def fitted(size)
        LIMITS.each do |limit|
          lines = yield limit
          return lines if lines.all? { |line| @measure.call(line, size) <= BOX_WIDTH }
        end
        nil
      end

      def clip(line, size)
        line = line[0...-1] until line.empty? || @measure.call(line, size) <= BOX_WIDTH
        line
      end

      def lines_within(text, size, limit, balance:)
        units = pieces(text, size, limit)
        # widths[i] counts a unit's trailing space, trimmed[i] does not: a line never ends with the space.
        widths = units.map { |unit| @measure.call(unit, size) }
        trimmed = units.map { |unit| unit.strip.empty? ? 0 : @measure.call(unit.rstrip, size) }
        totals = widths.each_with_object([0]) { |width, sums| sums << (sums.last + width) }
        span = ->(start, stop) { totals[stop - 1] - totals[start] + trimmed[stop - 1] }

        breaks = greedy(units.length, limit, span)
        breaks = balanced(units.length, breaks.length, limit, span) if balance && breaks.length <= capacity(size)
        ([0] + breaks).each_cons(2).map { |start, stop| units[start...stop].join.strip }.reject(&:empty?)
      end

      # Units that fit on a line stay whole. A longer one is cut by character.
      def pieces(text, size, limit)
        @segmenter.call(text).flat_map do |unit|
          @measure.call(unit.strip, size) <= limit ? [unit] : unit.chars
        end
      end

      # Returns the index after the last unit of each line.
      def greedy(count, limit, span)
        breaks = []
        start = 0
        (1..count).each do |stop|
          next unless stop - start > 1 && span.call(start, stop) > limit

          breaks << (stop - 1)
          start = stop - 1
        end
        count.zero? ? breaks : breaks << count
      end

      # Among the layouts with as few lines as the greedy one, the one whose widest line is narrowest.
      def balanced(count, line_count, limit, span)
        # best[line][stop] = [widest line so far, where the last line starts]
        best = Array.new(line_count + 1) { {} }
        best[0][0] = [0, nil]
        (1..line_count).each do |line|
          (line..count).each do |stop|
            (stop - 1).downto(line - 1) do |start|
              width = span.call(start, stop)
              break if width > limit && stop - start > 1

              previous = best[line - 1][start]
              next unless previous

              widest = [previous.first, width].max
              best[line][stop] = [widest, start] if best[line][stop].nil? || widest < best[line][stop].first
            end
          end
        end
        return greedy(count, limit, span) unless best[line_count][count]

        breaks = [count]
        line_count.downto(2) { |line| breaks.unshift(best[line][breaks.first].last) }
        breaks
      end

      def truncate(lines, size)
        last = lines.last.to_s
        last = last[0...-1] until last.empty? || @measure.call("#{last}#{ELLIPSIS}", size) <= BOX_WIDTH
        lines[0...-1] + ["#{last}#{ELLIPSIS}"]
      end
    end

    class Renderer
      FONT_PATH = File.expand_path("fonts/ZenAntique-Regular.ttf", __dir__)
      FONT_FAMILY = "Zen Antique"
      PAPER = [255, 255, 255].freeze
      INK = [0, 0, 0].freeze
      TEAL = [0, 210, 190].freeze
      CHIPS = [[255, 131, 137], TEAL, [0, 0, 255]].freeze
      MARGIN = 80
      BAR_HEIGHT = 24
      SITE_NAME = "weblog.ason.as"
      SITE_LEAD = "asonasの日記とかエッセイなどの文章が読めるサイトです。"
      MARK = "国"
      # Zen Antique's serifed "i" is far wider than a sans-serif fallback's, so this row tells the fonts apart.
      FONT_PROBE = "iiiiiiiiii"
      FONT_PROBE_WIDTH = 638

      def initialize
        # On macOS Pango draws through CoreText by default and ignores fontfile. The fontconfig backend, the default on Linux, reads it.
        ENV["PANGOCAIRO_BACKEND"] ||= "fc"
        require "vips"
        verify_font
        @layout = Layout.new(measure: method(:advance))
      end

      def article(title)
        layout = @layout.call(title)
        canvas = footer(paper, chip: 40, label: SITE_NAME)
        return png(canvas) if layout.lines.empty?

        block = text(layout.lines.join("\n"), layout.size)
        top = BAR_HEIGHT + ((HEIGHT - BAR_HEIGHT - 136 - block.height) / 2)
        png(ink(canvas, block, MARGIN, [top, BAR_HEIGHT + 24].max))
      end

      def home
        canvas = footer(paper, chip: 56)
        name = text(SITE_NAME, 124)
        lead = text(SITE_LEAD, 34)
        top = BAR_HEIGHT + ((HEIGHT - BAR_HEIGHT - 136 - name.height - 48 - lead.height) / 2)
        canvas = ink(canvas, name, MARGIN, top)
        png(ink(canvas, lead, MARGIN + 4, top + name.height + 48))
      end

      private

      def paper
        Vips::Image.black(WIDTH, HEIGHT, bands: 3).new_from_image(PAPER).copy(interpretation: :srgb)
          .draw_rect(TEAL, 0, 0, WIDTH, BAR_HEIGHT, fill: true)
      end

      def footer(canvas, chip:, label: nil)
        top = HEIGHT - 56 - chip
        CHIPS.each_with_index { |color, index| canvas = canvas.draw_rect(color, MARGIN + (index * chip), top, chip, chip, fill: true) }
        return canvas unless label

        name = text(label, 36)
        ink(canvas, name, MARGIN + (chip * CHIPS.length) + 24, top + ((chip - name.height) / 2))
      end

      # A one-band mask of the text. The font file is passed explicitly so nothing depends on fonts installed on the host.
      def text(string, size)
        draw(%(<span line_height="#{line_height(size)}">#{CGI.escapeHTML(string)}</span>), size)
      end

      def draw(markup, size)
        Vips::Image.text(markup, font: "#{FONT_FAMILY} #{size}", fontfile: FONT_PATH, dpi: 72)
      end

      # How far the text moves the pen, spaces included. The image of a text alone is only as wide as its ink,
      # so a trailing space would measure nothing; the text is drawn between two marks instead.
      def advance(string, size)
        text("#{MARK}#{string}#{MARK}", size).width - text(MARK * 2, size).width
      end

      # libvips only warns when it cannot load the font file and then draws with another font.
      # An image drawn that way would be stored under a key that is cached for a year.
      def verify_font
        width = draw(FONT_PROBE, 200).width
        return if (width - FONT_PROBE_WIDTH).abs <= FONT_PROBE_WIDTH * 0.05

        raise "#{FONT_FAMILY} was not used to draw text: the probe is #{width}px wide instead of #{FONT_PROBE_WIDTH}px"
      end

      # Pango's line_height multiplies the font's own line spacing, which is taller than its size.
      # This returns the factor that puts baselines Layout::LINE_HEIGHT × size apart.
      def line_height(size)
        @line_heights ||= {}
        @line_heights[size] ||= begin
          natural = draw("国\n国", size).height - draw("国", size).height
          (size * Layout::LINE_HEIGHT / natural).round(3)
        end
      end

      def ink(canvas, mask, left, top)
        overlay = mask.new_from_image(INK).copy(interpretation: :srgb).bandjoin(mask)
        canvas.composite(overlay, :over, x: left, y: top)
      end

      def png(image) = image.flatten(background: PAPER).write_to_buffer(".png", strip: true)
    end

    # Places an article's image where the public page expects it. Publication must not fail or stall because of it.
    class Store
      def initialize(s3_client:, bucket:, renderer: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @s3 = s3_client
        @bucket = bucket
        @renderer = renderer
        @clock = clock
      end

      # The worker that publishes an article goes on to refresh the cache, the feed, and the search index within one
      # invocation, and one diary can publish many linked articles. Images past the deadline are left to bin/backfill-og-images.
      def deadline(seconds) = @clock.call + seconds

      def ensure(page, deadline: nil)
        return nil if CoverImage.resolve(page)
        late = -> { deadline && @clock.call > deadline }
        return nil if late.call

        key = OgImage.key(page.display_title)
        return key if exists?(key)
        return nil if late.call

        @renderer ||= Renderer.new
        body = @renderer.article(page.display_title)
        return nil if late.call

        @s3.put_object(bucket: @bucket, key:, body:, content_type: "image/png", cache_control: CACHE_CONTROL)
        key
      rescue StandardError, LoadError => error
        warn "Could not create the Open Graph image for #{page.id}: #{error.class}: #{error.message}"
        nil
      end

      private

      def exists?(key)
        @s3.head_object(bucket: @bucket, key:)
        true
      rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::Forbidden, Aws::S3::Errors::AccessDenied
        # Without s3:ListBucket on this prefix a missing object answers 403.
        false
      end
    end
  end
end
