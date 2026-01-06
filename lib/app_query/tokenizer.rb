# frozen_string_literal: true

module AppQuery
  class Tokenizer
    class LexError < StandardError; end

    attr_reader :input, :tokens, :pos, :start

    def self.tokenize(...)
      new(...).run
    end

    def initialize(input, state: nil, start: nil, pos: nil)
      @input = input
      @tokens = []
      @start = start || 0
      @pos = pos || @start
      @return = Array(state || :lex_sql)
    end

    def err(msg)
      linepos = linepos_by_pos[pos] || linepos_by_pos[pos.pred]

      msg += <<~ERR

        #{input}
        #{" " * linepos}^
      ERR
      raise LexError, msg
    end

    def eos?
      pos == input.size
    end

    def chars_read
      input[start...pos]
    end

    def read_char(n = 1)
      @pos = [pos + n, input.size].min
      self
    end

    def rest
      input[pos...]
    end

    def match?(re)
      rest[Regexp.new("\\A%s" % re)]
    end

    def emit_token(t, v: nil)
      @tokens << {v: v || chars_read, t: t, start: start, end: pos}
      @start = @pos
      self
    end

    def push_return(*steps)
      (@return ||= []).push(*steps)
      self
    end

    def read_until(pattern)
      loop do
        break if match?(pattern) || eos?
        read_char
      end
    end

    def lex_sql
      if last_emitted? t: "CTE_SELECT", ignore: %w[WHITESPACE COMMENT]
        push_return :lex_select
      elsif match?(/\s/)
        push_return :lex_sql, :lex_whitespace
      elsif match_comment?
        push_return :lex_sql, :lex_comment
      elsif match?(/with/i)
        push_return :lex_sql, :lex_with
      else
        push_return :lex_select
      end
    end

    def lex_with
      err "Expected 'WITH'" unless match? %r{WITH\s}i
      read_until(/\s/)
      read_until(/\S/)
      emit_token "WITH"

      push_return :lex_recursive_cte
    end

    def lex_prepend_cte
      if eos?
        emit_token "COMMA", v: ","
        emit_token "WHITESPACE", v: "\n"
      elsif match?(/\s/)
        push_return :lex_prepend_cte, :lex_whitespace
      else
        push_return :lex_prepend_cte, :lex_recursive_cte
      end
    end

    def lex_append_cte
      emit_token "COMMA", v: ","
      emit_token "WHITESPACE", v: "\n  "
      push_return :lex_recursive_cte
    end

    def lex_recursive_cte
      if match?(/recursive\s/i)
        read_until(/\s/)
        # make trailing whitespace part of next token
        # this makes adding cte's easier
        read_until(/\S/)
        emit_token "RECURSIVE"
      end

      push_return :lex_cte
    end

    def last_emitted(ignore:)
      if ignore.none?
        @tokens.last
      else
        t = @tokens.dup
        while (result = t.pop)
          break if !ignore.include?(result[:t])
        end
        result
      end
    end

    def last_emitted?(ignore_whitespace: true, ignore: [], **kws)
      ignore = if ignore.any?
        ignore
      elsif ignore_whitespace
        %w[COMMENT WHITESPACE]
      else
        []
      end
      last_emitted(ignore:)&.slice(*kws.keys) == kws
    end

    def lex_cte
      if match_comment?
        push_return :lex_cte, :lex_comment
      elsif last_emitted? t: "CTE_IDENTIFIER", ignore_whitespace: true
        if match?(/AS(\s|\()/i)
          read_char 2
          emit_token "AS"

          push_return :lex_cte, :lex_cte_select, :lex_maybe_materialized, :lex_whitespace
        elsif match?(%r{\(})
          # "foo " "(id)"
          push_return :lex_cte, :lex_cte_columns
        else
          err "Expected 'AS' or CTE columns following CTE-identifier, e.g. 'foo AS' 'foo()'"
        end
      elsif last_emitted? t: "CTE_COLUMNS_CLOSE", ignore_whitespace: true
        if match?(/AS(\s|\()/i)
          read_char 2
          emit_token "AS"

          push_return :lex_cte, :lex_cte_select, :lex_maybe_materialized, :lex_whitespace
        else
          err "Expected 'AS' following CTE-columns"
        end
      elsif last_emitted? t: "CTE_SELECT", ignore_whitespace: true
        if match?(/,/)
          # but wait, there's more!
          read_char
          emit_token "CTE_COMMA"
          push_return :lex_cte, :lex_whitespace
        end
      else
        push_return :lex_cte, :lex_cte_identifier
      end
    end

    def lex_maybe_materialized
      if match?(/materialized/i)
        read_until(/\(/)
        emit_token "MATERIALIZED"
      elsif match?(%r{\(})
        # done
      elsif match?(/not\s/i)
        read_char 3
        read_until(/\S/)
        emit_token "NOT_MATERIALIZED"
        err "Expected 'MATERIALIZED'" unless match?(/materialized/i)

        push_return :lex_maybe_materialized
      else
        err "Expected CTE select or NOT? MATERIALIZED"
      end
    end

    def match_comment?
      match?(%r{--|/\*})
    end

    def lex_cte_columns
      err "Expected CTE columns, e.g. '(id, other)'" unless match? %r{\(}

      read_char
      read_until(/\S/)
      emit_token "CTE_COLUMNS_OPEN"

      loop do
        if match?(/\)/)
          err "Expected a column name" unless last_emitted? t: "CTE_COLUMN"

          read_char
          emit_token "CTE_COLUMNS_CLOSE"
          break
        elsif match?(/,/)
          # "( " ","
          err "Expected a column name" unless last_emitted? t: "CTE_COLUMN"
          read_char # ','

          read_until(/\S/)
          emit_token "CTE_COLUMN_DIV"
        elsif match?(/"/)
          unless last_emitted? t: "CTE_COLUMNS_OPEN"
            err "Expected comma" unless last_emitted? t: "CTE_COLUMN_DIV"
          end

          read_char
          read_until(/"/)
          read_char

          emit_token "CTE_COLUMN"
        elsif match?(/[_A-Za-z]/)
          unless last_emitted? t: "CTE_COLUMNS_OPEN"
            err "Expected comma" unless last_emitted? t: "CTE_COLUMN_DIV"
          end

          read_until %r{,|\s|\)}

          emit_token "CTE_COLUMN"
        elsif match?(/\s/)
          read_until(/\S/)
        else
          # e.g. "(id," "1)" or eos?
          err "Expected valid column name"
        end
      end

      push_return :lex_whitespace
    end

    def lex_cte_select
      err "Expected CTE select, e.g. '(select 1)'" unless match? %r{\(}
      read_char

      level = 1
      loop do
        read_until(/\)|\(|'/)
        if eos?
          err "CTE select ended prematurely"
        elsif match?(/'/)
          # Skip string literal (handle escaped quotes '')
          read_char
          loop do
            read_until(/'/)
            read_char
            break unless match?(/'/) # '' is escaped quote, continue
            read_char
          end
        elsif match?(/\(/)
          level += 1
          read_char
        elsif match?(/\)/)
          level -= 1
          break if level.zero?
          read_char
        end
      end

      err "Expected non-empty CTE select, e.g. '(select 1)'" if chars_read.strip == "("
      read_char
      emit_token "CTE_SELECT"

      push_return :lex_whitespace
    end

    def lex_cte_identifier
      err "Expected CTE identifier, e.g. 'foo', '\"foo bar\"' " unless match? %r{[_"A-Za-z]}

      if match?(/"/)
        read_char
        read_until(/"/)
        read_char
      else
        read_until %r{\s|\(}
      end
      emit_token "CTE_IDENTIFIER"

      push_return :lex_whitespace
    end

    # there should always be a SELECT
    def lex_select
      read_until(/\Z/)
      read_char

      if last_emitted? t: "COMMENT", ignore_whitespace: false
        emit_token "WHITESPACE", v: "\n"
      end
      emit_token "SELECT"
    end

    def lex_comment
      err "Expected comment, i.e. '--' or '/*'" unless match_comment?

      if match?("--")
        read_until(/\n/)
      else
        read_until %r{\*/}
        err "Expected comment close '*/'." if eos?
        read_char 2
      end

      emit_token "COMMENT"
      push_return :lex_whitespace
    end

    # optional
    def lex_whitespace
      if match?(/\s/)
        read_until(/\S/)

        emit_token "WHITESPACE"
      end
    end

    def run(pos: nil)
      loop do
        break if step.nil?
      end
      eos? ? tokens : self
    end

    def step
      if (state = @return.pop)
        method(state).call
        self
      end
    end

    private

    def linepos_by_pos
      linepos = 0
      input.each_char.each_with_index.each_with_object([]) do |(c, ix), acc|
        acc[ix] = linepos
        if c == "\n"
          linepos = 0
        else
          linepos += 1
        end
      end
    end
  end
end
