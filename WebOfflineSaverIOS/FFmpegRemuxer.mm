#import "FFmpegRemuxer.h"

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/error.h>
}

static NSString *WOSFFError(int code) {
    char buffer[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(code, buffer, sizeof(buffer));
    return [NSString stringWithUTF8String:buffer] ?: @"未知 FFmpeg 错误";
}

BOOL WOSRemuxHLS(NSURL *inputURL, NSURL *outputURL, NSString *referer, NSString *requestHeaders, NSString **errorMessage) {
    AVFormatContext *input = nullptr;
    AVFormatContext *output = nullptr;
    AVDictionary *options = nullptr;
    int result = 0;
    avformat_network_init();
    if (referer.length > 0) av_dict_set(&options, "referer", referer.UTF8String, 0);
    NSString *headers = [NSString stringWithFormat:@"Referer: %@\r\nUser-Agent: Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15\r\n%@", referer ?: @"", requestHeaders ?: @""];
    av_dict_set(&options, "headers", headers.UTF8String, 0);
    result = avformat_open_input(&input, inputURL.absoluteString.UTF8String, nullptr, &options);
    av_dict_free(&options);
    if (result < 0) goto fail;
    if ((result = avformat_find_stream_info(input, nullptr)) < 0) goto fail;
    if ((result = avformat_alloc_output_context2(&output, nullptr, "mp4", outputURL.path.UTF8String)) < 0 || !output) goto fail;
    for (unsigned i = 0; i < input->nb_streams; i++) {
        AVStream *inStream = input->streams[i];
        AVStream *outStream = avformat_new_stream(output, nullptr);
        if (!outStream || (result = avcodec_parameters_copy(outStream->codecpar, inStream->codecpar)) < 0) goto fail;
        outStream->codecpar->codec_tag = 0;
        outStream->time_base = inStream->time_base;
    }
    if (!(output->oformat->flags & AVFMT_NOFILE) && (result = avio_open(&output->pb, outputURL.path.UTF8String, AVIO_FLAG_WRITE)) < 0) goto fail;
    if ((result = avformat_write_header(output, nullptr)) < 0) goto fail;
    {
        AVPacket *packet = av_packet_alloc();
        if (!packet) { result = AVERROR(ENOMEM); goto fail; }
        while ((result = av_read_frame(input, packet)) >= 0) {
            AVStream *inStream = input->streams[packet->stream_index];
            AVStream *outStream = output->streams[packet->stream_index];
            packet->pts = av_rescale_q_rnd(packet->pts, inStream->time_base, outStream->time_base, (AVRounding)(AV_ROUND_NEAR_INF|AV_ROUND_PASS_MINMAX));
            packet->dts = av_rescale_q_rnd(packet->dts, inStream->time_base, outStream->time_base, (AVRounding)(AV_ROUND_NEAR_INF|AV_ROUND_PASS_MINMAX));
            packet->duration = av_rescale_q(packet->duration, inStream->time_base, outStream->time_base);
            packet->pos = -1;
            result = av_interleaved_write_frame(output, packet);
            av_packet_unref(packet);
            if (result < 0) break;
        }
        av_packet_free(&packet);
        if (result == AVERROR_EOF) result = 0;
    }
    if (result >= 0) result = av_write_trailer(output);
fail:
    if (result < 0 && errorMessage) *errorMessage = WOSFFError(result);
    if (output && !(output->oformat->flags & AVFMT_NOFILE) && output->pb) avio_closep(&output->pb);
    if (output) avformat_free_context(output);
    if (input) avformat_close_input(&input);
    avformat_network_deinit();
    return result >= 0;
}
