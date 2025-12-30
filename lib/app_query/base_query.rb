module AppQuery
  class BaseQuery
    class_attribute :_binds, default: {}
    class_attribute :_vars, default: {}
    class_attribute :_casts, default: {}

    class << self
      def bind(name, default: nil)
        self._binds = _binds.merge(name => { default: })
        attr_reader name
      end

      def var(name, default: nil)
        self._vars = _vars.merge(name => { default: })
        attr_reader name
      end

      def cast(casts = nil)
        return _casts if casts.nil?
        self._casts = casts
      end

      def binds = _binds
      def vars = _vars
    end

    def initialize(**params)
      all_known = self.class.binds.keys + self.class.vars.keys
      unknown = params.keys - all_known
      raise ArgumentError, "Unknown param(s): #{unknown.join(", ")}" if unknown.any?

      self.class.binds.merge(self.class.vars).each do |name, options|
        value = params.fetch(name) {
          default = options[:default]
          default.is_a?(Proc) ? instance_exec(&default) : default
        }
        instance_variable_set(:"@#{name}", value)
      end
    end

    delegate :select_all, :select_one, :count, :to_s, :column, :first, :ids, to: :query

    def entries
      select_all
    end

    def query
      @query ||= base_query
        .render(**render_vars)
        .with_binds(**bind_vars)
    end

    def base_query
      AppQuery[query_name, cast: self.class.cast]
    end

    private

    def query_name
      self.class.name.underscore.sub(/_query$/, "")
    end

    def render_vars
      self.class.vars.keys.to_h { [_1, send(_1)] }
    end

    def bind_vars
      self.class.binds.keys.to_h { [_1, send(_1)] }
    end
  end
end
