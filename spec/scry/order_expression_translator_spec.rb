# frozen_string_literal: true

require "rails_helper"

# rubocop:disable Metrics/BlockLength
RSpec.describe Scry::OrderExpressionTranslator do
  let(:source) { Arel::Table.new(:children) }
  let(:joined) { Arel::Table.new(:joined_children) }
  let(:identity_map) { { source => joined } }

  def translate(node)
    described_class.translate(node, relation_identity_map: identity_map)
  end

  it "rewrites attributes through the supplied relation identity map" do
    node = translate(source[:name].asc)

    expect(node).to be_a(Arel::Nodes::Ascending)
    expect(node.expr.relation).to equal(joined)
    expect(node.expr.name.to_s).to eq("name")
  end

  it "recursively translates custom named functions without a function whitelist" do
    node = translate(
      Arel::Nodes::NamedFunction.new(
        "LOWER",
        [Arel::Nodes::NamedFunction.new("COALESCE", [source[:name], Arel::Nodes.build_quoted("unknown")])]
      )
    )

    expect(node.to_sql).to include("LOWER(COALESCE(\"joined_children\".\"name\", 'unknown'))")
  end

  it "translates aggregate function nodes structurally" do
    node = translate(Arel::Nodes::Max.new([source[:score]]).desc)

    expect(node.expr).to be_a(Arel::Nodes::Max)
    expect(node.expr.expressions.first.relation).to equal(joined)
  end

  it "translates arithmetic and null ordering nodes" do
    expression = (source[:rank] + Arel::Nodes.build_quoted(1)).desc
    node = translate(Arel::Nodes::NullsLast.new(expression))

    expect(node).to be_a(Arel::Nodes::NullsLast)
    expect(node.expr).to be_a(Arel::Nodes::Descending)
    arithmetic = node.expr.expr.expr
    expect(arithmetic.left.relation).to equal(joined)
  end

  it "preserves the source tree while translating nulls first" do
    source_node = source[:name].asc
    node = translate(Arel::Nodes::NullsFirst.new(source_node))

    expect(node).to be_a(Arel::Nodes::NullsFirst)
    expect(node.expr.expr.relation).to equal(joined)
    expect(source_node.expr.relation).to equal(source)
  end

  it "accepts an explicit Arel.star but rejects arbitrary SQL literals" do
    expect(translate(Arel.star)).to be_a(Arel::Nodes::SqlLiteral)
    expect { translate(Arel.sql("children.name DESC")) }
      .to raise_error(Scry::FilterError, /unsupported order expression node/)
  end

  it "rejects attributes whose relation is not mapped" do
    expect { described_class.translate(Arel::Table.new(:other)[:name], relation_identity_map: identity_map) }
      .to raise_error(Scry::FilterError, /unmapped order expression attribute/)
  end

  it "does not treat an equal-by-name table as the mapped relation" do
    same_name_source = Arel::Table.new(:children)

    expect { described_class.translate(same_name_source[:name], relation_identity_map: identity_map) }
      .to raise_error(Scry::FilterError, /unmapped order expression attribute/)
  end

  it "keeps same-named self-join sources mapped to their own aliases" do
    parent_source = Arel::Table.new(:nodes)
    child_source = Arel::Table.new(:nodes)
    parent_join = parent_source.alias("parent_nodes")
    child_join = child_source.alias("child_nodes")
    self_join_map = {}.compare_by_identity
    self_join_map[parent_source] = parent_join
    self_join_map[child_source] = child_join

    parent_node = described_class.translate(parent_source[:name], relation_identity_map: self_join_map)
    child_node = described_class.translate(child_source[:name], relation_identity_map: self_join_map)

    expect(parent_node.relation).to equal(parent_join)
    expect(child_node.relation).to equal(child_join)
  end

  it "rejects unsupported function arguments with a readable error" do
    function = Arel::Nodes::NamedFunction.new("LOWER", [Arel.sql("children.name")])

    expect { translate(function) }
      .to raise_error(Scry::FilterError, /unsupported order expression node/)
  end

  it "rejects window nodes instead of traversing into a subquery-like expression" do
    window = Arel::Nodes::Over.new(Arel::Nodes::Max.new([source[:score]]), nil)

    expect { translate(window) }
      .to raise_error(Scry::FilterError, /unsupported order expression node/)
  end
end
# rubocop:enable Metrics/BlockLength
