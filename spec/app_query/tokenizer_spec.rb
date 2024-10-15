# frozen_string_literal: true

RSpec.describe AppQuery::Tokenizer do
  def tokenize(...)
    described_class.tokenize(...)
  end

  def lex_comment(s, **kws)
    described_class.new(s, state: :lex_comment, **kws).step
  end

  def emitted_tokens(s, steps: 1, **kws)
    described_class.new(s, **kws).tap {|t| steps.times { t.step } }.tokens
  end

  def emitted_token(...)
    emitted_tokens(...).last
  end

  describe "#lex_comment" do
    it "reads line comments correctly" do
      expect(emitted_tokens("-- some comment", state: :lex_comment)).to \
        include(a_hash_including(v: "-- some comment", t: "COMMENT"))

      expect(emitted_tokens("some -- some comment\n\n", state: :lex_comment, start: 5)).to \
        include(a_hash_including(v: "-- some comment", t: "COMMENT"))
    end

    it "reads multiline comments correctly" do
      expect(emitted_tokens("/* some\nmulti\nline\ncomment */ and more", state: :lex_comment)).to \
        include(a_hash_including(t: "COMMENT", v: "/* some\nmulti\nline\ncomment */"))
    end

    it "raises when no comment" do
      expect {
        emitted_tokens("not some comment", state: :lex_comment)
      }.to raise_error described_class::LexError, /expected comment/i
    end

    it "multi: raises when eos before end of comment" do
      expect {
        emitted_tokens("/* some", state: :lex_comment)
      }.to raise_error described_class::LexError, /expected comment close/i
    end
  end

  describe "#lex_whitespace" do
    it "allows for there to be no whitespace" do
      expect(emitted_tokens("no whitespace", state: :lex_whitespace)).to be_empty
    end

    it "emits whitespace and newlines till next word" do
      expect(emitted_tokens(" \n\n then some", state: :lex_whitespace)).to \
        include(a_hash_including(t: "WHITESPACE", v: " \n\n "))
    end

    it "emits whitespace and newlines till eos" do
      expect(emitted_tokens(" \n\n ", state: :lex_whitespace)).to \
        include(a_hash_including(t: "WHITESPACE", v: " \n\n "))
    end
  end

  describe "#lex_cte_select" do
    it "should start with '('"  do
      expect {
        emitted_tokens("select 1", state: :lex_cte_select)
      }.to raise_error described_class::LexError, /expected cte select/i
    end

    it "should have a non-blank select"  do
      expect {
        emitted_tokens("( )", state: :lex_cte_select)
      }.to raise_error described_class::LexError, /expected non-empty cte/i
    end

    it "emits everything up til ')'"  do
      expect(emitted_token("(select\n 1)", state: :lex_cte_select)).to \
        include(t: "CTE_SELECT", v: "(select\n 1)")
    end

    it "allows for nested parenthese"  do
      expect(emitted_token("(select * from (select 1) some_alias)", state: :lex_cte_select)).to \
        include(t: "CTE_SELECT", v: "(select * from (select 1) some_alias)")
    end

    it "raises when ending prematurely"  do
      expect {
        emitted_tokens("( select 1", state: :lex_cte_select)
      }.to raise_error described_class::LexError, /cte select ended prematurely/i
    end

    it "emits any trailing whitespace"  do
      expect(emitted_token("( select 1) ", state: :lex_cte_select, steps: 2)).to \
        include(t: "WHITESPACE")
    end
  end

  describe "#lex_cte_identifier" do
    def emitted_token_for_state(s, **kws)
      emitted_token(s, **kws.merge(state: :lex_cte_identifier))
    end

    it "raises when no identifier coming"  do
      expect {
        emitted_token_for_state(" ")
      }.to raise_error described_class::LexError, /expected cte identifier/i
    end

    it "emits a simple identifier" do
      expect(emitted_token_for_state("foo(id)")).to \
        include(v: "foo")

      expect(emitted_token_for_state("foo (id)")).to \
        include(v: "foo")
    end

    it "emits a quoted identifier" do
      expect(emitted_token_for_state(%{"foo bar" (id)})).to \
        include(v: %{"foo bar"})
    end

    it "emits any trailing whitespace" do
      expect(emitted_token_for_state(%{"foo bar" (id)}, steps: 2)).to \
        include(t: "WHITESPACE", v: %{ })
    end
  end

  describe "#lex_cte_columns" do
    def emitted_tokens_for_state(s, **kws)
      emitted_token(s, **kws.merge(state: :lex_cte_columns))
    end

    def emitted_token_for_state(s, **kws)
      emitted_token(s, **kws.merge(state: :lex_cte_columns))
    end

    it "raises when no CTE columns upcoming"  do
      expect {
        emitted_token_for_state("f")
      }.to raise_error described_class::LexError, /expected cte columns/i
    end

    it "raises when empty CTE columns"  do
      expect {
        emitted_token_for_state("( )")
      }.to raise_error described_class::LexError, /expected a column/i
    end

    it "raises when column absent"  do
      expect {
        emitted_token_for_state("(id,)")
      }.to raise_error described_class::LexError, /expected a column/i
    end

    it "raises when column absent"  do
      expect {
        emitted_token_for_state("(,foo)")
      }.to raise_error described_class::LexError, /expected a column/i
    end

    it "emits all columns" do
      tokens = emitted_tokens(%{(id, "foo")}, state: :lex_cte_columns)

      expect(tokens).to \
        include(a_hash_including(t: "CTE_COLUMN", v: "id")).and \
        include(a_hash_including(t: "CTE_COLUMN", v: %{"foo"}))
    end

    it "emits any trailing whitespace" do
      expect(emitted_tokens("(id) ", state: :lex_cte_columns, steps: 2)).to \
        include(a_hash_including(t: "WHITESPACE"))
    end
  end

  describe "#lex_select" do
    it "should emit something" do
      expect {
        emitted_tokens("\n ", state: :lex_select)
      }.to raise_error described_class::LexError, /expected a select/i
    end
  end
end
