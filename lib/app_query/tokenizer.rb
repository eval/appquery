# frozen_string_literal: true

require "strscan"

module AppQuery
  class Tokenizer
    LexError = Class.new(StandardError)

    attr_reader :input, :tokens, :state, :pos, :start

    def self.tokenize(...)
      new(...).run
    end

    def initialize(input, state: nil, start: nil, pos: nil)
      @input = input
      @tokens = []
      @state = state || :lex_sql
      @start = start || 0
      @pos = pos || @start
      @return = []
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

    def emit_token(t)
      @tokens << {v: chars_read, t: t, start: start, end: pos}
      @start = @pos
      self
    end

    def assoc_state(s)
      @state = if s == :return
        @return.pop
      else
        s
      end
      self
    end

    def push_return(s)
      (@return||= []).push(s)
      self
    end

    def read_until(pattern)
      loop do
        break if match?(pattern) || eos?
        read_char
      end
    end

    def lex_sql
      if match? /\s/
        assoc_state :lex_whitespace
        push_return :lex_sql
      elsif match? /--|\/\*/
        assoc_state :lex_comment
        push_return :lex_sql
      elsif match? /with/i
        assoc_state :lex_with
        push_return :lex_sql
      else
        assoc_state :lex_select
      end
    end

    def lex_with
      err "Expected 'WITH'" unless match? %r[WITH ?$]i
      read_until /\s/
      emit_token "WITH"

      assoc_state :lex_whitespace
      push_return :lex_cte
    end

    def last_emitted(ignore_whitespace: true)
      unless ignore_whitespace
        @tokens.last
      else
        t = @tokens.dup
        while (result = t.pop) do
          break if result[:t] != "WHITESPACE"
        end
        result
      end
    end

    def last_emitted?(ignore_whitespace: true, **kws)
      last_emitted(ignore_whitespace:) && last_emitted.slice(*kws.keys) == kws
    end

    def lex_cte
      if last_emitted? t: "CTE_IDENTIFIER", ignore_whitespace: true
        case
        when match?(/AS/i)
          read_char 2
          emit_token "AS"

          assoc_state :lex_whitespace
          push_return :lex_cte
          push_return :lex_cte_select
        when match?(%r[\(])
          # "foo " "(id)"
          assoc_state :lex_cte_columns
          push_return :lex_cte
        else
          err "Expected 'AS' or CTE columns following CTE-identifier, e.g. 'foo AS' 'foo()'"
        end
      elsif last_emitted? t: "CTE_COLUMNS_CLOSE", ignore_whitespace: true
        case
        when match?(/AS/i)
          read_char 2
          emit_token "AS"

          assoc_state :lex_whitespace
          push_return :lex_cte
          push_return :lex_cte_select
        else
          err "Expected 'AS' following CTE-columns"
        end
      elsif last_emitted? t: "CTE_SELECT", ignore_whitespace: true
        case
        when match?(/,/)
          # but wait, there's more!
          read_char
          emit_token "CTE_COMMA"
          assoc_state :lex_whitespace
          push_return :lex_cte
        else
          assoc_state :return
        end
      else
        assoc_state :lex_cte_identifier

        push_return :lex_cte
      end
    end

    def lex_cte_columns
      # TODO handle ambiguity for "with foo (select 1)"
      err "Expected CTE columns, e.g. '(id, other)'" unless match? %r[\(]

      read_char
      read_until /\S/
      emit_token "CTE_COLUMNS_OPEN"

      loop do
        case
        when match?(/\)/)
          err "Expected a column name" unless last_emitted? t: "CTE_COLUMN"

          read_char
          emit_token "CTE_COLUMNS_CLOSE"
          break
        when match?(/,/)
          # "( " ","
          err "Expected a column name" unless last_emitted? t: "CTE_COLUMN"
          read_char # ','

          read_until /\S/
          emit_token "CTE_COLUMN_DIV"
        when match?(/"/)
          unless last_emitted? t: "CTE_COLUMNS_OPEN"
            err "Expected comma" unless last_emitted? t: "CTE_COLUMN_DIV"
          end

          read_char
          read_until /"/
          read_char

          emit_token "CTE_COLUMN"
        when match?(/[A-Za-z]/)
          unless last_emitted? t: "CTE_COLUMNS_OPEN"
            err "Expected comma" unless last_emitted? t: "CTE_COLUMN_DIV"
          end

          read_until %r[,|\s|\)]

          emit_token "CTE_COLUMN"
        when match?(/\s/)
          read_until /\S/
        else
          # e.g. "(id," "1)" or eos?
          err "Expected valid column name"
        end
      end

      assoc_state :lex_whitespace
    end

    def lex_cte_select
      err "Expected CTE select, e.g. '(select 1)'" unless match? %r[\(]
      read_char

      level = 1
      loop do
        read_until /\)|\(/
        case
        when eos?
          err "CTE select ended prematurely"
        when match?(/\(/) then level += 1
        when match?(/\)/)
          level -= 1
          break if level.zero?
        end
        read_char
      end

      err "Expected non-empty CTE select, e.g. '(select 1)'" if chars_read.strip == "("
      read_char
      emit_token "CTE_SELECT"

      assoc_state :lex_whitespace
    end

    def lex_cte_identifier
      err "Expected CTE identifier, e.g. 'foo', '\"foo bar\"' " unless match? %r[["A-Za-z]]

      if match? /"/
        read_char
        read_until /"/
        read_char

        emit_token "CTE_IDENTIFIER"
      else
        read_until %r[\s|\(]

        emit_token "CTE_IDENTIFIER"
      end

      assoc_state :lex_whitespace
    end

    def lex_select
      read_until /\Z/
      emit_token "SELECT"

      assoc_state :return
    end

    def lex_comment
      err "Expected comment, i.e. '--' or '/*'" unless match? %r[--|\/\*]

      case
      when match?("--")
        read_until /\n/
      else
        read_until %r[\*/]
        err "Expected comment close '*/'." if eos?
        read_char 2
      end

      emit_token "COMMENT"

      assoc_state :return
    end

    # fine if there's no whitespace upcoming
    def lex_whitespace
      if match? /\s/
        read_until /\S/

        emit_token "WHITESPACE"
      end

      assoc_state :return
    end

    def run(pos: nil)
      loop do
        break if step.nil?
      end
      eos? ? tokens : self
    end

    def step
      method(state).call if state
    end

    private


    def linepos_by_pos
      linepos = 0
      @linepos ||= input.each_char.each_with_index.each_with_object([]) do |(c, ix),acc|
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

=begin
  Begin in de state "lex_sql" en lees alle comments, whitespace weg en stop met eos
=end
