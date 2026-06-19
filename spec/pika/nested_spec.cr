require "../spec_helper"

# ---------------------------------------------------------------------------
# Nested-object params via Pika.object
# ---------------------------------------------------------------------------

Pika.object Address do
  field street : String
  field city   : String
  field zip    : String?
end

Pika.object LineItem do
  field sku : String
  field qty : Int32
end

class NestedAPI < Pika::API
  resource :orders do
    params do
      requires customer : String
      requires address  : Address
      requires items    : Array(LineItem)
      optional billing  : Address?
    end
    post do
      {
        customer: declared_params.customer,
        street:   declared_params.address.street,
        zip:      declared_params.address.zip,
        first_sku: declared_params.items.first.sku,
        item_count: declared_params.items.size,
        has_billing: !declared_params.billing.nil?,
      }.to_json
    end
  end
end

describe "nested object params" do
  it "coerces a nested object and an array of nested objects" do
    response = NestedAPI.request(:post, "/orders", json: {
      customer: "ada",
      address:  {street: "1 Main", city: "Algy", zip: "12345"},
      items:    [{sku: "A1", qty: 2}, {sku: "B2", qty: 5}],
    })
    response.status.should eq(200)
    response.json["street"].as_s.should eq("1 Main")
    response.json["zip"].as_s.should eq("12345")
    response.json["first_sku"].as_s.should eq("A1")
    response.json["item_count"].as_i.should eq(2)
    response.json["has_billing"].as_bool.should be_false
  end

  it "accepts an optional nested object when present" do
    response = NestedAPI.request(:post, "/orders", json: {
      customer: "ada",
      address:  {street: "1 Main", city: "Algy"},
      items:    [{sku: "A1", qty: 2}],
      billing:  {street: "2 Side", city: "Algy"},
    })
    response.status.should eq(200)
    response.json["has_billing"].as_bool.should be_true
  end

  it "treats a nilable nested object as nil when absent" do
    response = NestedAPI.request(:post, "/orders", json: {
      customer: "ada",
      address:  {street: "1 Main", city: "Algy"},
      items:    [{sku: "A1", qty: 2}],
    })
    response.status.should eq(200)
    response.json["zip"].as_s?.should be_nil
  end

  it "returns 422 when a required nested object is missing" do
    response = NestedAPI.request(:post, "/orders", json: {
      customer: "ada",
      items:    [{sku: "A1", qty: 2}],
    })
    response.status.should eq(422)
    response.body.should contain("is required")
  end

  it "returns 422 when a nested object is missing a required field" do
    response = NestedAPI.request(:post, "/orders", json: {
      customer: "ada",
      address:  {city: "Algy"},                 # missing required street
      items:    [{sku: "A1", qty: 2}],
    })
    response.status.should eq(422)
    response.body.should contain("must be a valid object")
  end

  it "returns 422 when an array element is malformed" do
    response = NestedAPI.request(:post, "/orders", json: {
      customer: "ada",
      address:  {street: "1 Main", city: "Algy"},
      items:    [{sku: "A1"}],                   # missing required qty
    })
    response.status.should eq(422)
    response.body.should contain("must be an array of valid objects")
  end
end

describe "nested objects in OpenAPI" do
  doc = JSON.parse(NestedAPI.openapi_doc)

  it "references the nested object schema via \$ref" do
    props = doc["paths"]["/orders"]["post"]["requestBody"]["content"]["application/json"]["schema"]["properties"].as_h
    props["address"]["$ref"].as_s.should eq("#/components/schemas/Address")
  end

  it "represents an array of nested objects with items \$ref" do
    props = doc["paths"]["/orders"]["post"]["requestBody"]["content"]["application/json"]["schema"]["properties"].as_h
    props["items"]["type"].as_s.should eq("array")
    props["items"]["items"]["$ref"].as_s.should eq("#/components/schemas/LineItem")
  end

  it "emits the nested schemas into components/schemas with their fields" do
    schemas = doc["components"]["schemas"].as_h
    schemas.has_key?("Address").should be_true
    schemas.has_key?("LineItem").should be_true
    addr = schemas["Address"]
    addr["type"].as_s.should eq("object")
    addr["properties"].as_h.keys.should contain("street")
    addr["required"].as_a.map(&.as_s).should contain("street")
    addr["required"].as_a.map(&.as_s).should_not contain("zip")
  end
end
