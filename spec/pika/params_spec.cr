require "../spec_helper"

# Minimal test API to exercise the params DSL and validate! generation
class TestParamsAPI < Pika::API
  resource :test_params do
    params do
      requires email : String, regexp: /@/
      optional age : Int32 = 0, values: 1..120
    end
    post do
      "ok"
    end
  end
end

describe "params DSL" do
  it "accepts valid input" do
    raw = {"email" => "alice@example.com", "age" => "25"}
    p = TestParamsAPI.validate_pikap_test_params_post!(raw)
    p.email.should eq("alice@example.com")
    p.age.should eq(25)
  end

  it "uses default when optional param is omitted" do
    raw = {"email" => "bob@example.com"}
    p = TestParamsAPI.validate_pikap_test_params_post!(raw)
    p.age.should eq(0)
  end

  it "raises ValidationError when required param missing" do
    raw = {} of String => String
    expect_raises(Pika::ValidationError) do
      TestParamsAPI.validate_pikap_test_params_post!(raw)
    end
  end

  it "raises ValidationError for regexp mismatch" do
    raw = {"email" => "notanemail"}
    expect_raises(Pika::ValidationError) do
      TestParamsAPI.validate_pikap_test_params_post!(raw)
    end
  end

  it "raises ValidationError for out-of-range value" do
    raw = {"email" => "x@y.com", "age" => "999"}
    expect_raises(Pika::ValidationError) do
      TestParamsAPI.validate_pikap_test_params_post!(raw)
    end
  end
end
