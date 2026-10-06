require "test_helper"

class ProdigiSpinePdfTest < ActiveSupport::TestCase
  def snapshot(**changes)
    { "title" => "Synthetic journeys · Été", "spine_text" => "", "format" => "landscape_a4",
      "background_color" => "#ffffff", "text_color" => "#202020" }.merge(changes.stringify_keys)
  end

  test "blank labels use the book name and embed both template fonts at valid spine widths" do
    PhotoBook::FORMATS.each do |format, dimensions|
      [ 2.0, 8.0, 20.0 ].each do |width|
        bytes = ProdigiSpinePdf.new(snapshot(format: format), width_mm: width).render
        assert bytes.start_with?("%PDF-")
        assert_equal 2, bytes.scan("/FontFile2").size
        box = bytes.match(/\/MediaBox\s+\[([^\]]+)\]/)[1].split.map(&:to_f)
        assert_in_delta width * PhotoBookLayout::POINTS_PER_MM, box[2], 0.01
        assert_in_delta dimensions.fetch(:height) * PhotoBookLayout::POINTS_PER_MM, box[3], 0.01
      end
    end
  end

  test "custom and long labels fit and the selected printable title is validated" do
    [ "Custom title · Été", "Long synthetic title " * 9 ].each do |label|
      assert ProdigiSpinePdf.new(snapshot(spine_text: label), width_mm: 8.0).render.start_with?("%PDF-")
    end
    assert_raises(ProdigiClient::Error) { ProdigiSpinePdf.new(snapshot(title: "Unsupported 🚀"), width_mm: 8.0).render }
    assert ProdigiSpinePdf.new(snapshot(title: "Unsupported 🚀", spine_text: "Printable override"), width_mm: 8.0).render.start_with?("%PDF-")
  end

  test "invalid spine widths cannot produce printable artwork" do
    [ 0.0, 1.0, 81.0, Float::NAN, Float::INFINITY ].each do |width|
      assert_raises(ProdigiClient::Error) { ProdigiSpinePdf.new(snapshot, width_mm: width).render }
    end
  end
end
