#define NOMINMAX

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <opencv2/opencv.hpp>
#include <qpdf/Buffer.hh>
#include <qpdf/Pl_Buffer.hh>
#include <qpdf/QPDF.hh>
#include <qpdf/QPDFObjGen.hh>
#include <qpdf/QPDFObjectHandle.hh>
#include <qpdf/QPDFWriter.hh>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <windows.h>

namespace fs = std::filesystem;

struct DebugCounters {
  int total_images = 0;
  int skipped_no_filter_data = 0;
  int skipped_decode_fail = 0;
  int skipped_colorspace = 0;
  int skipped_seh_or_exception = 0;
  int processed_ok = 0;
};

struct ExtractedImage {
  QPDFObjGen obj_gen;
  cv::Mat mat;
  size_t orig_raw_size = 0;
  int orig_channels = 0;
};

// Fast CMYK -> BGR without per-pixel float division or Mat::at overhead
static cv::Mat convert_cmyk_to_bgr_fast(int width, int height,
                                        const unsigned char *buf_data) {
  cv::Mat bgr(height, width, CV_8UC3);
  for (int r = 0; r < height; ++r) {
    const unsigned char *src = buf_data + static_cast<size_t>(r) * width * 4;
    unsigned char *dst = bgr.ptr<unsigned char>(r);
    for (int c = 0; c < width; ++c) {
      const uint32_t invC = 255u - src[0];
      const uint32_t invM = 255u - src[1];
      const uint32_t invY = 255u - src[2];
      const uint32_t invK = 255u - src[3];
      dst[0] = static_cast<unsigned char>((invY * invK + 127u) / 255u);
      dst[1] = static_cast<unsigned char>((invM * invK + 127u) / 255u);
      dst[2] = static_cast<unsigned char>((invC * invK + 127u) / 255u);
      src += 4;
      dst += 3;
    }
  }
  return bgr;
}

static bool extract_single_image_impl(QPDFObjectHandle &obj,
                                      QPDFObjectHandle &dict,
                                      ExtractedImage &out_item,
                                      DebugCounters &dbg) {
  // 1. Abaikan ImageMask (Stencil Mask) agar layout/vektor tidak rusak
  if (dict.hasKey("/ImageMask") && dict.getKey("/ImageMask").isBool() &&
      dict.getKey("/ImageMask").getBoolValue()) {
    return false;
  }

  size_t raw_size = 0;
  try {
    auto raw_stream = obj.getRawStreamData();
    if (raw_stream) {
      raw_size = raw_stream->getSize();
    }
  } catch (...) {
    if (dict.hasKey("/Length") && dict.getKey("/Length").isInteger()) {
      auto len = dict.getKey("/Length").getIntValue();
      if (len > 0)
        raw_size = static_cast<size_t>(len);
    }
  }

  Pl_Buffer buf_pipeline("image_pipe");
  try {
    obj.pipeStreamData(&buf_pipeline, 0, qpdf_dl_generalized);
  } catch (...) {
    dbg.skipped_decode_fail++;
    return false;
  }

  std::unique_ptr<Buffer> decoded_buf(buf_pipeline.getBuffer());
  if (!decoded_buf || decoded_buf->getSize() == 0) {
    dbg.skipped_no_filter_data++;
    return false;
  }

  const unsigned char *buf_data = decoded_buf->getBuffer();
  size_t buf_size = decoded_buf->getSize();
  if (raw_size == 0) {
    raw_size = buf_size;
  }

  cv::Mat raw_img;
  try {
    cv::Mat encoded_view(1, static_cast<int>(buf_size), CV_8UC1,
                         const_cast<unsigned char *>(buf_data));
    raw_img = cv::imdecode(encoded_view, cv::IMREAD_UNCHANGED);
  } catch (...) {
    raw_img.release();
  }

  if (raw_img.empty()) {
    if (!dict.hasKey("/Width") || !dict.hasKey("/Height")) {
      dbg.skipped_decode_fail++;
      return false;
    }

    int width = dict.getKey("/Width").getIntValueAsInt();
    int height = dict.getKey("/Height").getIntValueAsInt();
    int bpc = dict.hasKey("/BitsPerComponent")
                  ? dict.getKey("/BitsPerComponent").getIntValueAsInt()
                  : 8;

    if (width <= 0 || height <= 0 || bpc != 8) {
      dbg.skipped_decode_fail++;
      return false;
    }

    int channels = 0;
    if (dict.hasKey("/ColorSpace")) {
      QPDFObjectHandle cs = dict.getKey("/ColorSpace");
      std::string cs_name;
      if (cs.isName())
        cs_name = cs.getName();
      else if (cs.isArray() && cs.getArrayNItems() > 0 &&
               cs.getArrayItem(0).isName()) {
        cs_name = cs.getArrayItem(0).getName();
      }

      if (cs_name == "/DeviceRGB" || cs_name == "/CalRGB")
        channels = 3;
      else if (cs_name == "/DeviceGray" || cs_name == "/CalGray")
        channels = 1;
      else if (cs_name == "/DeviceCMYK")
        channels = 4;
    }

    if (channels == 0) {
      const size_t px_count = static_cast<size_t>(width) * height;
      if (buf_size >= px_count * 4)
        channels = 4;
      else if (buf_size >= px_count * 3)
        channels = 3;
      else if (buf_size >= px_count)
        channels = 1;
    }

    if (channels == 0 ||
        buf_size < static_cast<size_t>(width) * height * channels) {
      dbg.skipped_colorspace++;
      return false;
    }

    if (channels == 1) {
      raw_img =
          cv::Mat(height, width, CV_8UC1, const_cast<unsigned char *>(buf_data))
              .clone();
    } else if (channels == 3) {
      cv::Mat rgb(height, width, CV_8UC3,
                  const_cast<unsigned char *>(buf_data));
      cv::cvtColor(rgb, raw_img, cv::COLOR_RGB2BGR);
    } else if (channels == 4) {
      raw_img = convert_cmyk_to_bgr_fast(width, height, buf_data);
    }
  }

  if (raw_img.empty() || raw_img.cols <= 0 || raw_img.rows <= 0) {
    dbg.skipped_decode_fail++;
    return false;
  }

  if (raw_img.channels() == 4) {
    cv::cvtColor(raw_img, raw_img, cv::COLOR_BGRA2BGR);
  }

  out_item.obj_gen = obj.getObjGen();
  out_item.mat = std::move(raw_img);
  out_item.orig_raw_size = raw_size;
  out_item.orig_channels = out_item.mat.channels();
  dbg.processed_ok++;
  return true;
}

static bool extract_single_image_cpp_safe(QPDFObjectHandle &obj,
                                          QPDFObjectHandle &dict,
                                          ExtractedImage &out_item,
                                          DebugCounters &dbg) {
  try {
    return extract_single_image_impl(obj, dict, out_item, dbg);
  } catch (...) {
    dbg.skipped_seh_or_exception++;
    return false;
  }
}

static bool safe_extract_image_with_seh(QPDFObjectHandle *obj,
                                        QPDFObjectHandle *dict,
                                        ExtractedImage *out_item,
                                        DebugCounters *dbg) {
  __try {
    return extract_single_image_cpp_safe(*obj, *dict, *out_item, *dbg);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    dbg->skipped_seh_or_exception++;
    return false;
  }
}

static std::vector<cv::Mat>
prepare_mats_for_dim(const std::vector<ExtractedImage> &items, int max_dim,
                     unsigned num_threads) {
  std::vector<cv::Mat> mats(items.size());
  if (max_dim <= 0) {
    for (size_t i = 0; i < items.size(); ++i) {
      mats[i] = items[i].mat;
    }
    return mats;
  }

  std::atomic<size_t> next_idx{0};
  auto worker = [&]() {
    while (true) {
      size_t i = next_idx.fetch_add(1, std::memory_order_relaxed);
      if (i >= items.size())
        break;
      const cv::Mat &src = items[i].mat;
      int max_curr = std::max(src.cols, src.rows);
      if (max_curr > max_dim) {
        double scale = static_cast<double>(max_dim) / max_curr;
        cv::resize(src, mats[i], cv::Size(), scale, scale, cv::INTER_AREA);
      } else {
        mats[i] = src;
      }
    }
  };

  unsigned t_count =
      std::max(1u, std::min<unsigned>(num_threads, (unsigned)items.size()));
  if (t_count == 1) {
    worker();
    return mats;
  }

  std::vector<std::thread> threads;
  threads.reserve(t_count);
  for (unsigned t = 0; t < t_count; ++t) {
    threads.emplace_back(worker);
  }
  for (auto &th : threads) {
    th.join();
  }
  return mats;
}

struct EncodedBatch {
  std::vector<std::vector<unsigned char>> jpegs;
  std::vector<int> widths;
  std::vector<int> heights;
  std::vector<int> channels;
  uintmax_t est_total_bytes = 0;
};

static EncodedBatch encode_batch_parallel(
    const std::vector<ExtractedImage> &items, const std::vector<cv::Mat> &mats,
    int quality, bool prefer_resized, uintmax_t non_image_bytes,
    unsigned num_threads) {
  EncodedBatch batch;
  const size_t n = items.size();
  batch.jpegs.resize(n);
  batch.widths.assign(n, 0);
  batch.heights.assign(n, 0);
  batch.channels.assign(n, 0);

  std::vector<size_t> item_contribution(n, 0);
  std::atomic<size_t> next_idx{0};

  auto worker = [&]() {
    const std::vector<int> params = {cv::IMWRITE_JPEG_QUALITY, quality};
    while (true) {
      size_t i = next_idx.fetch_add(1, std::memory_order_relaxed);
      if (i >= n)
        break;
      const cv::Mat &m = mats[i];
      const bool was_resized =
          (m.cols != items[i].mat.cols || m.rows != items[i].mat.rows);
      std::vector<unsigned char> encoded;
      try {
        if (cv::imencode(".jpg", m, encoded, params) && !encoded.empty()) {
          if (encoded.size() < items[i].orig_raw_size ||
              (prefer_resized && was_resized)) {
            item_contribution[i] = encoded.size();
            batch.jpegs[i] = std::move(encoded);
            batch.widths[i] = m.cols;
            batch.heights[i] = m.rows;
            batch.channels[i] = m.channels();
            continue;
          }
        }
      } catch (...) {
      }
      item_contribution[i] = items[i].orig_raw_size;
    }
  };

  unsigned t_count = std::max(1u, std::min<unsigned>(num_threads, (unsigned)n));
  if (t_count == 1) {
    worker();
  } else {
    std::vector<std::thread> threads;
    threads.reserve(t_count);
    for (unsigned t = 0; t < t_count; ++t) {
      threads.emplace_back(worker);
    }
    for (auto &th : threads) {
      th.join();
    }
  }

  uintmax_t img_sum = 0;
  for (size_t sz : item_contribution) {
    img_sum += sz;
  }
  // Small header overhead safety slack when dict keys are updated per replaced image
  batch.est_total_bytes = non_image_bytes + img_sum + static_cast<uintmax_t>(n) * 48;
  return batch;
}

static std::shared_ptr<Buffer>
assemble_pdf_in_memory(const Buffer &flate_pdf_buf,
                       const std::vector<ExtractedImage> &items,
                       const EncodedBatch &batch) {
  QPDF pdf;
  pdf.processMemoryFile(
      "flate_base.pdf",
      reinterpret_cast<char const *>(flate_pdf_buf.getBuffer()),
      flate_pdf_buf.getSize());

  if (!items.empty()) {
    std::unordered_map<uint64_t, size_t> lookup;
    lookup.reserve(items.size() * 2);
    auto make_key = [](int objid, int gen) -> uint64_t {
      return (static_cast<uint64_t>(static_cast<uint32_t>(objid)) << 16) |
             static_cast<uint32_t>(gen);
    };
    for (size_t i = 0; i < items.size(); ++i) {
      if (!batch.jpegs[i].empty()) {
        lookup[make_key(items[i].obj_gen.getObj(), items[i].obj_gen.getGen())] =
            i;
      }
    }

    if (!lookup.empty()) {
      for (auto &obj : pdf.getAllObjects()) {
        if (!obj.isStream())
          continue;
        auto it = lookup.find(make_key(obj.getObjectID(), obj.getGeneration()));
        if (it == lookup.end())
          continue;

        const size_t idx = it->second;
        const auto &jpg = batch.jpegs[idx];
        auto new_buf = std::make_shared<Buffer>(jpg.size());
        std::memcpy(new_buf->getBuffer(), jpg.data(), jpg.size());

        QPDFObjectHandle dict = obj.getDict();
        dict.replaceKey("/Filter", QPDFObjectHandle::newName("/DCTDecode"));
        dict.replaceKey("/ColorSpace",
                        QPDFObjectHandle::newName(batch.channels[idx] == 1
                                                      ? "/DeviceGray"
                                                      : "/DeviceRGB"));
        dict.replaceKey("/Width",
                        QPDFObjectHandle::newInteger(batch.widths[idx]));
        dict.replaceKey("/Height",
                        QPDFObjectHandle::newInteger(batch.heights[idx]));
        dict.replaceKey("/BitsPerComponent", QPDFObjectHandle::newInteger(8));
        dict.removeKey("/DecodeParms");

        obj.replaceStreamData(new_buf, QPDFObjectHandle::newName("/DCTDecode"),
                              QPDFObjectHandle::newNull());
      }
    }
  }

  QPDFWriter writer(pdf);
  writer.setOutputMemory();
  writer.setCompressStreams(true);
  writer.setDecodeLevel(qpdf_dl_generalized);
  writer.setObjectStreamMode(qpdf_o_generate);
  // All non-image streams in flate_pdf_buf are already maximally Flate-compressed
  writer.setRecompressFlate(false);
  writer.write();
  return writer.getBufferSharedPointer();
}

static bool write_buffer_to_file(const std::string &output_path,
                                 const Buffer &buf) {
  std::ofstream out(fs::path(output_path), std::ios::binary | std::ios::trunc);
  if (!out)
    return false;
  out.write(reinterpret_cast<const char *>(buf.getBuffer()),
            static_cast<std::streamsize>(buf.getSize()));
  return out.good();
}

static int run_compression_pipeline(const std::string &input_path,
                                    const std::string &output_path,
                                    int target_kb, uintmax_t orig_size_kb) {
  std::shared_ptr<Buffer> flate_buf;
  const bool try_heavy_flate =
      orig_size_kb <= static_cast<uintmax_t>(target_kb) * 2;
  {
    QPDF pdf_in;
    pdf_in.processFile(input_path.c_str());

    QPDFWriter writer(pdf_in);
    writer.setOutputMemory();
    writer.setCompressStreams(true);
    writer.setDecodeLevel(try_heavy_flate ? qpdf_dl_generalized : qpdf_dl_none);
    writer.setObjectStreamMode(qpdf_o_generate);
    writer.setRecompressFlate(try_heavy_flate);
    writer.write();
    flate_buf = writer.getBufferSharedPointer();
  }

  if (!flate_buf || flate_buf->getSize() == 0) {
    return 1;
  }

  const uintmax_t flate_size_kb = flate_buf->getSize() / 1024;
  if (flate_size_kb <= static_cast<uintmax_t>(target_kb)) {
    std::cout << "[HASIL AKHIR] Optimasi struktur lossless: " << flate_size_kb
              << " KB (Target: " << target_kb << " KB)" << std::endl;
    return write_buffer_to_file(output_path, *flate_buf) ? 0 : 1;
  }

  // Extract & decode all image streams ONCE from the normalized PDF buffer
  std::vector<ExtractedImage> items;
  uintmax_t total_orig_image_bytes = 0;
  DebugCounters dbg;
  {
    QPDF pdf_work;
    pdf_work.processMemoryFile(
        "flate_extract.pdf",
        reinterpret_cast<char const *>(flate_buf->getBuffer()),
        flate_buf->getSize());

    for (auto &obj : pdf_work.getAllObjects()) {
      if (!obj.isStream())
        continue;
      QPDFObjectHandle dict = obj.getDict();
      if (!dict.hasKey("/Subtype"))
        continue;
      QPDFObjectHandle subtype = dict.getKey("/Subtype");
      if (!subtype.isName() || subtype.getName() != "/Image")
        continue;

      dbg.total_images++;
      ExtractedImage item;
      if (safe_extract_image_with_seh(&obj, &dict, &item, &dbg)) {
        total_orig_image_bytes += item.orig_raw_size;
        items.push_back(std::move(item));
      }
    }
  }

  if (items.empty()) {
    std::cout << "[HASIL AKHIR] Ukuran Output (tanpa gambar dapat dikompresi): "
              << flate_size_kb << " KB (Target: " << target_kb << " KB)"
              << std::endl;
    return write_buffer_to_file(output_path, *flate_buf) ? 0 : 1;
  }

  const uintmax_t non_image_bytes =
      (flate_buf->getSize() > total_orig_image_bytes)
          ? (flate_buf->getSize() - total_orig_image_bytes)
          : 0;

  const unsigned hw = std::thread::hardware_concurrency();
  const unsigned num_threads = std::max(1u, std::min<unsigned>(hw > 0 ? hw : 4u, 8u));

  // Prepare full-res view ONCE
  std::vector<cv::Mat> full_mats = prepare_mats_for_dim(items, 0, num_threads);

  int low_q = 30;
  int high_q = 100;
  int best_q = -1;
  EncodedBatch best_batch;

  // 1. In-memory parallel quality binary search with early floor check at Q=30
  {
    const int initial_q = 65;
    EncodedBatch cand65 = encode_batch_parallel(
        items, full_mats, initial_q, false, non_image_bytes, num_threads);
    uintmax_t est65_kb = cand65.est_total_bytes / 1024;
    std::cout << "[BINARY SEARCH] Uji Quality=" << initial_q
              << "% -> Estimasi: " << est65_kb << " KB" << std::endl;

    if (est65_kb <= static_cast<uintmax_t>(target_kb)) {
      best_q = initial_q;
      best_batch = std::move(cand65);
      low_q = initial_q + 1;
    } else {
      EncodedBatch cand30 = encode_batch_parallel(
          items, full_mats, 30, false, non_image_bytes, num_threads);
      uintmax_t est30_kb = cand30.est_total_bytes / 1024;
      std::cout << "[BINARY SEARCH] Uji Quality=30% -> Estimasi: " << est30_kb
                << " KB" << std::endl;
      if (est30_kb <= static_cast<uintmax_t>(target_kb)) {
        best_q = 30;
        best_batch = std::move(cand30);
        low_q = 31;
        high_q = initial_q - 1;
      } else {
        // Bahkan Quality 30% penuh masih > target_kb -> langsung ke fallback resolusi
        low_q = 1;
        high_q = 0;
      }
    }
  }

  while (low_q <= high_q) {
    int mid_q = low_q + (high_q - low_q) / 2;
    EncodedBatch candidate = encode_batch_parallel(
        items, full_mats, mid_q, false, non_image_bytes, num_threads);
    uintmax_t est_kb = candidate.est_total_bytes / 1024;
    std::cout << "[BINARY SEARCH] Uji Quality=" << mid_q
              << "% -> Estimasi: " << est_kb << " KB" << std::endl;

    if (est_kb <= static_cast<uintmax_t>(target_kb)) {
      best_q = mid_q;
      best_batch = std::move(candidate);
      low_q = mid_q + 1;
    } else {
      high_q = mid_q - 1;
    }
  }

  std::shared_ptr<Buffer> final_buf;
  uintmax_t final_size_kb = 0;

  if (best_q != -1) {
    final_buf = assemble_pdf_in_memory(*flate_buf, items, best_batch);
    final_size_kb = final_buf->getSize() / 1024;

    int adj_q = best_q;
    for (int retry = 0;
         retry < 3 && final_size_kb > static_cast<uintmax_t>(target_kb) &&
         adj_q > 30;
         ++retry) {
      int step = std::max(
          2, static_cast<int>((final_size_kb - target_kb) * 18 /
                              std::max<uintmax_t>(1, target_kb)) +
                 2);
      adj_q = std::max(30, adj_q - step);
      EncodedBatch adj_batch = encode_batch_parallel(
          items, full_mats, adj_q, false, non_image_bytes, num_threads);
      final_buf = assemble_pdf_in_memory(*flate_buf, items, adj_batch);
      final_size_kb = final_buf->getSize() / 1024;
    }
  }

  // 2. Fallback downscale resolusi ONLY jika Quality 30% masih > target_kb
  if (!final_buf || final_size_kb > static_cast<uintmax_t>(target_kb)) {
    const int dims[] = {3200, 2400, 1800, 1200, 800, 500};
    for (int d : dims) {
      std::vector<cv::Mat> dim_mats =
          prepare_mats_for_dim(items, d, num_threads);
      EncodedBatch cand = encode_batch_parallel(items, dim_mats, 80, true,
                                                non_image_bytes, num_threads);
      uintmax_t est_kb = cand.est_total_bytes / 1024;
      if (est_kb <= static_cast<uintmax_t>(target_kb) || d == 500) {
        // Jika ada ruang target > 10%, naikkan quality ke 90 untuk menjaga ketajaman
        if (est_kb * 10 <= static_cast<uintmax_t>(target_kb) * 9) {
          EncodedBatch cand90 = encode_batch_parallel(
              items, dim_mats, 90, true, non_image_bytes, num_threads);
          if (cand90.est_total_bytes / 1024 <=
              static_cast<uintmax_t>(target_kb)) {
            cand = std::move(cand90);
          }
        }
        auto built = assemble_pdf_in_memory(*flate_buf, items, cand);
        uintmax_t built_kb = built->getSize() / 1024;
        if (!final_buf || built_kb < final_size_kb) {
          final_buf = built;
          final_size_kb = built_kb;
        }
        if (final_size_kb <= static_cast<uintmax_t>(target_kb)) {
          break;
        }
        if (d == 500) {
          for (int q_step : {60, 40}) {
            EncodedBatch cand_q = encode_batch_parallel(
                items, dim_mats, q_step, true, non_image_bytes, num_threads);
            auto built_q = assemble_pdf_in_memory(*flate_buf, items, cand_q);
            uintmax_t built_q_kb = built_q->getSize() / 1024;
            if (built_q_kb < final_size_kb) {
              final_buf = built_q;
              final_size_kb = built_q_kb;
            }
            if (final_size_kb <= static_cast<uintmax_t>(target_kb))
              break;
          }
        }
      }
    }
  }

  if (!final_buf || final_buf->getSize() == 0) {
    return 1;
  }

  if (!write_buffer_to_file(output_path, *final_buf)) {
    return 1;
  }

  std::cout << "[HASIL AKHIR] Ukuran Output: " << final_size_kb
            << " KB (Target: " << target_kb << " KB)" << std::endl;
  return 0;
}

int main(int argc, char *argv[]) {
  if (argc < 3)
    return 1;
  std::string input_path = argv[1];
  std::string output_path = argv[2];
  int target_kb = (argc >= 4) ? std::atoi(argv[3]) : 0;

  std::error_code ec_stat;
  uintmax_t orig_bytes = fs::file_size(input_path, ec_stat);
  if (ec_stat) {
    std::cerr << "[ERROR] Gagal membaca ukuran file input: " << input_path
              << " (" << ec_stat.message() << ")" << std::endl;
    return 1;
  }
  uintmax_t orig_size_kb = orig_bytes / 1024;

  // Proteksi jika targetKB >= ukuran asli
  if (target_kb <= 0 || static_cast<uintmax_t>(target_kb) >= orig_size_kb) {
    std::cout << "[INFO] Target (" << target_kb << " KB) >= Ukuran Asli ("
              << orig_size_kb << " KB). Memakai file asli." << std::endl;
    std::error_code ec_copy;
    fs::copy_file(input_path, output_path, fs::copy_options::overwrite_existing,
                  ec_copy);
    return ec_copy ? 1 : 0;
  }

  try {
    return run_compression_pipeline(input_path, output_path, target_kb,
                                    orig_size_kb);
  } catch (...) {
    return 1;
  }
}
