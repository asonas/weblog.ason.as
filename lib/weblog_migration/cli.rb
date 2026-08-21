# frozen_string_literal: true

require "optparse"
require "pathname"
require "fileutils"

module WeblogMigration
  module CLI
    module_function

    def migrate(argv)
      options = { url_metadata: nil, asset_dir: nil }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: migrate --input EXPORT --output DIR --report DIR"
        opts.on("--input PATH", "Scrapbox export JSON") { |value| options[:input] = Pathname(value) }
        opts.on("--output PATH", "normalized output directory") { |value| options[:output] = Pathname(value) }
        opts.on("--report PATH", "report directory") { |value| options[:report] = Pathname(value) }
        opts.on("--url-metadata PATH", "fetched URL metadata JSON") { |value| options[:url_metadata] = Pathname(value) }
        opts.on("--asset-dir PATH", "downloaded URL preview image directory") { |value| options[:asset_dir] = Pathname(value) }
      end
      parser.parse!(argv)
      missing = %i[input output report].reject { |key| options.key?(key) }
      raise OptionParser::MissingArgument, missing.map { |key| "--#{key}" }.join(", ") unless missing.empty?
      raise OptionParser::InvalidArgument, "input file does not exist: #{options[:input]}" unless options[:input].file?

      FileUtils.mkdir_p(options[:output])
      FileUtils.mkdir_p(options[:report])
      project = Scrapbox.load_export(options[:input])
      normalized = Normalize.normalize_project(project, options[:output])
      AssetManifest.write_asset_manifest(options[:output], normalized)
      index_path = options[:output].join("index", "log.sqlite3")
      index = Index.build_index(normalized, index_path)
      site_path = options[:output].join("site")
      Render.render_site(
        normalized,
        index,
        site_path,
        url_metadata_path: options[:url_metadata],
        asset_dir: options[:asset_dir] || options[:output].join("assets")
      )
      Report.write_reports(options[:report], options[:input], project, normalized, index_path:, site_path:)
      0
    end
  end
end
