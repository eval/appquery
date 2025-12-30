# frozen_string_literal: true

module AppQuery
  # Adds pagination support to query classes.
  #
  # Provides two modes:
  # - **With count**: Full pagination with page numbers (uses COUNT query)
  # - **Without count**: Simple prev/next for large datasets (uses limit+1 trick)
  #
  # Compatible with Kaminari view helpers.
  #
  # @example Basic usage
  #   class ApplicationQuery < AppQuery::BaseQuery
  #     include AppQuery::Paginatable
  #     per_page 50
  #   end
  #
  #   class ArticlesQuery < ApplicationQuery
  #     per_page 10
  #   end
  #
  #   # With count (full pagination)
  #   articles = ArticlesQuery.new.paginate(page: 1).entries
  #   articles.total_pages  # => 5
  #   articles.current_page # => 1
  #
  #   # Without count (large datasets)
  #   articles = ArticlesQuery.new.paginate(page: 1, without_count: true).entries
  #   articles.next_page    # => 2 (or nil if last page)
  module Paginatable
    extend ActiveSupport::Concern

    # Kaminari-compatible wrapper for paginated results.
    class PaginatedResult
      include Enumerable
      delegate :each, :size, :[], :empty?, :first, :last, to: :@records

      def initialize(records, page:, per_page:, total_count: nil, has_next: nil)
        @records = records
        @page = page
        @per_page = per_page
        @total_count = total_count
        @has_next = has_next
      end

      def current_page = @page
      def limit_value = @per_page
      def prev_page = @page > 1 ? @page - 1 : nil
      def first_page? = @page == 1

      def total_count
        @total_count || raise("total_count not available in without_count mode")
      end

      def total_pages
        return nil unless @total_count
        (@total_count.to_f / @per_page).ceil
      end

      def next_page
        if @total_count
          @page < total_pages ? @page + 1 : nil
        else
          @has_next ? @page + 1 : nil
        end
      end

      def last_page?
        if @total_count
          @page >= total_pages
        else
          !@has_next
        end
      end

      def out_of_range?
        empty? && @page > 1
      end

      def transform!
        @records = @records.map { |r| yield(r) }
        self
      end
    end

    included do
      var :page, default: nil
      var :per_page, default: -> { self.class.per_page }
    end

    class_methods do
      def per_page(value = nil)
        if value.nil?
          return @per_page if defined?(@per_page)
          superclass.respond_to?(:per_page) ? superclass.per_page : 25
        else
          @per_page = value
        end
      end
    end

    def paginate(page: 1, per_page: self.class.per_page, without_count: false)
      @page = page
      @per_page = per_page
      @without_count = without_count
      self
    end

    def entries
      @_entries ||= build_paginated_result(super)
    end

    def total_count
      @_total_count ||= unpaginated_query.count
    end

    def unpaginated_query
      base_query
        .render(**render_vars.except(:page, :per_page))
        .with_binds(**bind_vars)
    end

    private

    def build_paginated_result(entries)
      return entries unless @page # No pagination requested

      if @without_count
        has_next = entries.size > @per_page
        records = has_next ? entries.first(@per_page) : entries
        PaginatedResult.new(records, page: @page, per_page: @per_page, has_next: has_next)
      else
        PaginatedResult.new(entries, page: @page, per_page: @per_page, total_count: total_count)
      end
    end

    def render_vars
      vars = super
      # Fetch one extra row in without_count mode to detect if there's more
      if @without_count && vars[:per_page]
        vars = vars.merge(per_page: vars[:per_page] + 1)
      end
      vars
    end
  end
end
