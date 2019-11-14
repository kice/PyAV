from libc.stdint cimport uint8_t

cimport libav as lib

from av.enum cimport define_enum
from av.error cimport err_check
from av.video.format cimport VideoFormat
from av.video.frame cimport alloc_video_frame


Interpolation = define_enum('Interpolation', (
    ('FAST_BILINEAR', lib.SWS_FAST_BILINEAR),
    ('BILINEAR', lib.SWS_BILINEAR),
    ('BICUBIC', lib.SWS_BICUBIC),
    ('X', lib.SWS_X),
    ('POINT', lib.SWS_POINT),
    ('AREA', lib.SWS_AREA),
    ('BICUBLIN', lib.SWS_BICUBLIN),
    ('GAUSS', lib.SWS_GAUSS),
    ('SINC', lib.SWS_SINC),
    ('LANCZOS', lib.SWS_LANCZOS),
    ('SPLINE', lib.SWS_SPLINE),
))

Colorspace = define_enum('Colorspace', (

    ('ITU709', lib.SWS_CS_ITU709),
    ('FCC', lib.SWS_CS_FCC),
    ('ITU601', lib.SWS_CS_ITU601),
    ('SMPTE170M', lib.SWS_CS_SMPTE170M),
    ('SMPTE240M', lib.SWS_CS_SMPTE240M),
    ('DEFAULT', lib.SWS_CS_DEFAULT),

    # Lowercase for b/c.
    ('itu709', lib.SWS_CS_ITU709),
    ('fcc', lib.SWS_CS_FCC),
    ('itu601', lib.SWS_CS_ITU601),
    ('itu624', lib.SWS_CS_SMPTE170M),
    ('smpte240', lib.SWS_CS_SMPTE240M),
    ('default', lib.SWS_CS_DEFAULT),

))


cdef class VideoReformatter(object):

    def __dealloc__(self):
        with nogil:
            lib.sws_freeContext(self.ptr)

    def reformat(self, VideoFrame frame not None, width=None, height=None,
                 format=None, src_colorspace=None, dst_colorspace=None,
                 interpolation=None):
        """Create a new :class:`VideoFrame` with the given width/height/format/colorspace.

        :param int width: New width, or ``None`` for the same width.
        :param int height: New height, or ``None`` for the same height.
        :param str format: New format, or ``None`` for the same format; see :attr:`VideoFrame.format`.
        :param Colorspace src_colorspace: Current colorspace.
        :param Colorspace dst_colorspace: Desired colorspace.
        :param Interpolation interpolation: The interpolation method to use.

        """

        cdef VideoFormat video_format = VideoFormat(format if format is not None else frame.format)
        cdef int c_src_colorspace = (Colorspace[src_colorspace] if src_colorspace is not None else Colorspace.DEFAULT).value
        cdef int c_dst_colorspace = (Colorspace[dst_colorspace] if dst_colorspace is not None else Colorspace.DEFAULT).value
        cdef int c_interpolation = (Interpolation[interpolation] if interpolation is not None else Interpolation.BILINEAR).value

        return self._reformat(
            frame,
            width or frame.ptr.width,
            height or frame.ptr.height,
            video_format.pix_fmt,
            c_src_colorspace,
            c_dst_colorspace,
            c_interpolation,
        )

    cdef _reformat(self, VideoFrame frame, int width, int height,
                   lib.AVPixelFormat dst_format, int src_colorspace,
                   int dst_colorspace, int interpolation):

        if frame.ptr.format < 0:
            raise ValueError("Frame does not have format set.")

        cdef lib.AVPixelFormat src_format = <lib.AVPixelFormat> frame.ptr.format

        # Shortcut!
        if (
            dst_format == src_format and
            width == frame.ptr.width and
            height == frame.ptr.height and
            dst_colorspace == src_colorspace
        ):
            return frame

        # Try and reuse existing SwsContextProxy
        # VideoStream.decode will copy its SwsContextProxy to VideoFrame
        # So all Video frames from the same VideoStream should have the same one
        with nogil:
            self.ptr = lib.sws_getCachedContext(
                self.ptr,
                frame.ptr.width,
                frame.ptr.height,
                src_format,
                width,
                height,
                dst_format,
                interpolation,
                NULL,
                NULL,
                NULL
            )

        # We want to change the colorspace transforms. We do that by grabbing
        # all of the current settings, changing a couple, and setting them all.
        # We need a lot of state here.
        cdef const int *inv_tbl
        cdef const int *tbl
        cdef int src_range, dst_range, brightness, contrast, saturation
        cdef int ret
        if src_colorspace != dst_colorspace:

            with nogil:

                # Casts for const-ness, because Cython isn't expressive enough.
                ret = lib.sws_getColorspaceDetails(
                    self.ptr,
                    <int**>&inv_tbl,
                    &src_range,
                    <int**>&tbl,
                    &dst_range,
                    &brightness,
                    &contrast,
                    &saturation
                )

            err_check(ret)

            with nogil:

                # Grab the coefficients for the requested transforms.
                # The inv_table brings us to linear, and `tbl` to the new space.
                if src_colorspace != lib.SWS_CS_DEFAULT:
                    inv_tbl = lib.sws_getCoefficients(src_colorspace)
                if dst_colorspace != lib.SWS_CS_DEFAULT:
                    tbl = lib.sws_getCoefficients(dst_colorspace)

                # Apply!
                ret = lib.sws_setColorspaceDetails(
                    self.ptr,
                    inv_tbl,
                    src_range,
                    tbl,
                    dst_range,
                    brightness,
                    contrast,
                    saturation
                )

            err_check(ret)

        # Create a new VideoFrame.
        cdef VideoFrame new_frame = alloc_video_frame()
        new_frame._copy_internal_attributes(frame)
        new_frame._init(dst_format, width, height)

        # Finally, scale the image.
        with nogil:
            lib.sws_scale(
                self.ptr,
                # Cast for const-ness, because Cython isn't expressive enough.
                <const uint8_t**>frame.ptr.data,
                frame.ptr.linesize,
                0,  # slice Y
                frame.ptr.height,
                new_frame.ptr.data,
                new_frame.ptr.linesize,
            )

        return new_frame
