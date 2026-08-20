# frozen_string_literal: true

require "pathname"
require "securerandom"

module WeblogAuthoring
  TOKYO_OFFSET = "+09:00"

  RepositorySnapshot = Struct.new(:pages, :problems, :redirects, keyword_init: true) do
    def initialize(pages: [], problems: [], redirects: [])
      super(pages: Array(pages).freeze, problems: Array(problems).freeze, redirects: Array(redirects).freeze)
      freeze
    end

    def with_redirect(old_route:, new_route:)
      redirect = Redirect.new(old_route:, new_route:)
      return self if redirects.include?(redirect)

      self.class.new(pages:, problems:, redirects: redirects + [redirect])
    end
  end

  class FileTransaction
    def initialize
      @writes = {}
      @deletes = {}
    end

    def write(path, content)
      resolved_path = Pathname(path)
      @writes[resolved_path] = content
      @deletes.delete(resolved_path)
    end

    def delete(path)
      resolved_path = Pathname(path)
      @deletes[resolved_path] = true unless @writes.key?(resolved_path)
    end

    def commit
      affected_paths = (@writes.keys + @deletes.keys).uniq
      original = affected_paths.each_with_object({}) do |path, values|
        values[path] = path.binread if path.exist?
      end
      created = affected_paths - original.keys

      begin
        @writes.each do |path, content|
          replace(path, content)
        end
        @deletes.each_key do |path|
          path.unlink if path.exist?
        end
      rescue StandardError => error
        rollback(original, created, error)
      end
    end

    private

    def rollback(original, created, original_error)
      rollback_errors = []

      original.each do |path, content|
        replace(path, content)
      rescue StandardError => error
        rollback_errors << error
      end

      created.each do |path|
        path.unlink if path.exist?
      rescue StandardError => error
        rollback_errors << error
      end

      if rollback_errors.empty?
        raise original_error
      end

      details = rollback_errors.map(&:message).join("; ")
      raise RuntimeError, "file transaction failed: #{original_error.message}; rollback failed: #{details}"
    end

    def replace(path, content)
      path.dirname.mkpath
      temporary = path.dirname.join(".#{path.basename}.#{SecureRandom.hex(8)}.tmp")

      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |stream|
        stream.binmode
        stream.write(content)
        stream.flush
        stream.fsync
      end

      File.rename(temporary, path)
    ensure
      temporary.unlink if temporary&.exist?
    end
  end

  class ContentRepository
    attr_reader :content_dir, :database_path, :database

    def initialize(content_dir, database_path, clock)
      @content_dir = Pathname(content_dir)
      @database_path = Pathname(database_path)
      @clock = clock
      @database = AuthoringDatabase.new(@database_path)
    end

    def refresh
      pages = []
      problems = []
      page_ids = {}
      routes = {}

      if content_dir.exist?
        Pathname.glob(content_dir.join("*.md").to_s).sort.each do |path|
          parsed = parse_path(path, problems)
          next if parsed.nil?

          begin
            document = with_links_and_tokyo_time(validate_external_document(parsed))
          rescue ArgumentError => error
            problems << PageProblem.new(path:, detail: error.message)
            next
          end

          if page_ids.key?(document.id)
            problems << PageProblem.new(path:, detail: "duplicate page id: #{document.id}")
            next
          end
          if routes.key?(document.route)
            problems << PageProblem.new(path:, detail: "duplicate route: #{document.route}")
            next
          end

          page_ids[document.id] = true
          routes[document.route] = true
          pages << document
        end
      end

      snapshot = RepositorySnapshot.new(pages:, problems:)
      database.rebuild(snapshot)
      snapshot
    end

    def get_page(page_id)
      refresh.pages.find { |page| page.id == page_id }
    end

    def find_route(route)
      normalized = route.to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
      refresh.pages.find { |page| page.route == normalized }
    end

    def list_pages(query: "", status: nil, empty_only: false)
      normalized_query = query.to_s.downcase

      refresh.pages.select do |page|
        status_match = status.nil? || page.status == status
        empty_match = !empty_only || page.empty?
        query_match = normalized_query.empty? ||
          page.display_title.downcase.include?(normalized_query) ||
          page.route.downcase.include?(normalized_query)
        status_match && empty_match && query_match
      end
    end

    def save_draft(request)
      snapshot = refresh
      current = current_page(snapshot, request.page_id)
      document = if current.nil?
        new_document(snapshot, request)
      else
        validate_expected_update(current, request)
        replace_document(
          current,
          body: request.body,
          title: current.page_type == "date" ? request.title : nil,
          updated_at: now
        )
      end

      document = with_links_and_tokyo_time(document)
      transaction = FileTransaction.new
      transaction.write(document.path, WeblogAuthoring.serialize_document(document))

      existing_names = snapshot.pages.each_with_object({}) do |page, names|
        names[page.name] = true unless page.name.nil?
      end

      document.links.each do |link|
        name = WeblogAuthoring.validate_page_name(link.name)
        next if existing_names.key?(name)

        empty_page = new_empty_named_page(snapshot, name)
        transaction.write(empty_page.path, WeblogAuthoring.serialize_document(empty_page))
        existing_names[name] = true
      end

      transaction.commit
      refresh
      get_page(document.id) || document
    end

    def rename_named_page(page_id, new_name)
      snapshot = refresh
      page = current_page(snapshot, page_id)
      raise ConflictError, "page does not exist: #{page_id}" if page.nil?
      raise ConflictError, "only named pages can be renamed" unless page.page_type == "named"

      normalized_name = WeblogAuthoring.validate_page_name(new_name)
      return page if normalized_name == page.name

      destination = WeblogAuthoring.page_path(content_dir, "named", name: normalized_name, page_date: nil)
      if snapshot.pages.any? { |other| other.id != page.id && other.name == normalized_name } || destination.exist?
        raise ConflictError, "page name already exists: #{normalized_name}"
      end

      changed_at = now
      renamed_page = replace_document(page, name: normalized_name, path: destination, updated_at: changed_at)
      transaction = FileTransaction.new

      snapshot.pages.each do |source|
        if source.id == page.id
          transaction.write(destination, WeblogAuthoring.serialize_document(renamed_page))
          next
        end

        body = WeblogAuthoring.replace_wiki_links(source.body, old_name: page.name.to_s, new_name: normalized_name)
        next if body == source.body

        updated_page = replace_document(source, body:, updated_at: changed_at)
        transaction.write(updated_page.path, WeblogAuthoring.serialize_document(updated_page))
      end

      transaction.delete(page.path)
      transaction.commit
      refresh
      get_page(page.id) || renamed_page
    end

    private

    def parse_path(path, problems)
      text = path.read(encoding: "UTF-8")
      parsed = WeblogAuthoring.parse_document(path, text)
      if parsed.is_a?(PageProblem)
        problems << parsed
        return nil
      end

      parsed
    rescue ArgumentError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError => error
      problems << PageProblem.new(path:, detail: "document is not UTF-8: #{error.message}")
      nil
    end

    def current_page(snapshot, page_id)
      return nil if page_id.nil?

      snapshot.pages.find { |page| page.id == page_id }
    end

    def new_document(snapshot, request)
      timestamp = now

      case request.page_type
      when "date"
        raise ArgumentError, "date pages require page_date" unless request.page_date.instance_of?(Date)
        if snapshot.pages.any? { |page| page.page_date == request.page_date }
          raise ConflictError, "date page already exists: #{request.page_date.iso8601}"
        end

        path = WeblogAuthoring.page_path(content_dir, "date", name: nil, page_date: request.page_date)
        raise ConflictError, "source path already exists: #{path.basename}" if path.exist?

        PageDocument.new(
          id: SecureRandom.uuid.delete("-"),
          page_type: "date",
          name: nil,
          page_date: request.page_date,
          title: request.title,
          status: "draft",
          created_at: timestamp,
          updated_at: timestamp,
          published_at: nil,
          path:,
          body: request.body,
          links: []
        )
      when "named"
        name = WeblogAuthoring.validate_page_name(request.name.to_s)
        if snapshot.pages.any? { |page| page.name == name }
          raise ConflictError, "page name already exists: #{name}"
        end

        path = WeblogAuthoring.page_path(content_dir, "named", name:, page_date: nil)
        raise ConflictError, "source path already exists: #{path.basename}" if path.exist?

        PageDocument.new(
          id: SecureRandom.uuid.delete("-"),
          page_type: "named",
          name:,
          page_date: nil,
          title: nil,
          status: "draft",
          created_at: timestamp,
          updated_at: timestamp,
          published_at: nil,
          path:,
          body: request.body,
          links: []
        )
      else
        raise ArgumentError, "unknown page type: #{request.page_type}"
      end
    end

    def new_empty_named_page(snapshot, name)
      new_document(snapshot, SaveRequest.new(page_type: "named", name:, body: ""))
    end

    def validate_expected_update(page, request)
      return if request.expected_updated_at.nil? || request.expected_updated_at == page.updated_at

      raise ConflictError, "page was updated by another edit"
    end

    def now
      value = @clock.call
      raise ArgumentError, "clock must return a Time" unless value.is_a?(Time)

      value.getlocal(TOKYO_OFFSET)
    end

    def validate_external_document(document)
      case document.page_type
      when "named"
        raise ArgumentError, "named pages must not have page_date" unless document.page_date.nil?
        normalized_name = WeblogAuthoring.validate_page_name(document.name.to_s)
        raise ArgumentError, "named page name must be normalized" unless normalized_name == document.name
      when "date"
        raise ArgumentError, "date pages must not have name" unless document.name.nil?
      else
        raise ArgumentError, "unknown page type: #{document.page_type}"
      end

      expected_path = WeblogAuthoring.page_path(
        content_dir,
        document.page_type,
        name: document.name,
        page_date: document.page_date
      )
      raise ArgumentError, "document is not at canonical source path: #{expected_path.basename}" unless document.path == expected_path

      document
    end

    def with_links_and_tokyo_time(document)
      [document.created_at, document.updated_at, document.published_at].compact.each do |value|
        raise ArgumentError, "document timestamps must be aware" if value.utc_offset.nil?
      end

      links = WeblogAuthoring.extract_wiki_links(document.body)
      links.each do |link|
        WeblogAuthoring.validate_page_name(link.name)
      end

      replace_document(
        document,
        created_at: document.created_at.getlocal(TOKYO_OFFSET),
        updated_at: document.updated_at.getlocal(TOKYO_OFFSET),
        published_at: document.published_at&.getlocal(TOKYO_OFFSET),
        links:
      )
    end

    def replace_document(document, **changes)
      PageDocument.new(**document.to_h.merge(changes))
    end
  end
end
