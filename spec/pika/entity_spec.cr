require "../spec_helper"

# ---------------------------------------------------------------------------
# Test model
# ---------------------------------------------------------------------------

struct Article
  getter id : Int32
  getter title : String
  getter body : String
  getter draft : Bool

  def initialize(@id, @title, @body, @draft = false)
  end
end

# ---------------------------------------------------------------------------
# Entities under test
# ---------------------------------------------------------------------------

class ArticleEntity < Pika::Entity(Article)
  pika_entity do
    expose :id
    expose :title
    expose :body,  if: :full
    expose :draft, if: :admin
    expose(:slug) { |a| a.title.downcase.gsub(/\s+/, "-") }
  end
end

# ---------------------------------------------------------------------------
# Specs
# ---------------------------------------------------------------------------

describe "Pika::Entity" do
  article = Article.new(1, "Hello World", "Long body text", draft: true)

  describe "unconditional expose" do
    it "includes always-exposed fields" do
      json = JSON.parse(ArticleEntity.represent(article))
      json["id"].as_i.should eq(1)
      json["title"].as_s.should eq("Hello World")
    end
  end

  describe "conditional expose with if: :flag" do
    it "omits field when flag not passed" do
      json = JSON.parse(ArticleEntity.represent(article))
      json["body"]?.should be_nil
    end

    it "includes field when flag is true" do
      json = JSON.parse(ArticleEntity.represent(article, full: true))
      json["body"].as_s.should eq("Long body text")
    end

    it "respects independent flags" do
      json = JSON.parse(ArticleEntity.represent(article, full: true))
      json["draft"]?.should be_nil

      json2 = JSON.parse(ArticleEntity.represent(article, admin: true))
      json2["draft"].as_bool.should eq(true)
    end
  end

  describe "expose with block" do
    it "uses the block return value as the field value" do
      json = JSON.parse(ArticleEntity.represent(article))
      json["slug"].as_s.should eq("hello-world")
    end
  end

  describe "collection represent" do
    it "returns a JSON array" do
      a2 = Article.new(2, "Second Post", "body2")
      json = JSON.parse(ArticleEntity.represent([article, a2]))
      json.as_a.size.should eq(2)
      json[0]["id"].as_i.should eq(1)
      json[1]["id"].as_i.should eq(2)
    end

    it "passes options to each item" do
      json = JSON.parse(ArticleEntity.represent([article], full: true))
      json[0]["body"].as_s.should eq("Long body text")
    end
  end
end
