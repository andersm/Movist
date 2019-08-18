/*
 * ColorConversions.c
 * Created by Alexander Strange on 1/10/07.
 *
 * This file is part of Perian.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include "ColorConversions.h"
#include <Accelerate/Accelerate.h>
#include <stdio.h>

/*
 Converts (without resampling) from ffmpeg pixel formats to the ones QT accepts
 
 Todo:
 - rewrite everything in asm (or C with all loop optimization opportunities removed)
 - add a version with bilinear resampling
 - handle YUV 4:2:0 with odd width
 */

#define unlikely(x) __builtin_expect(x, 0)
#define likely(x) __builtin_expect(x, 1)

//Handles the last row for Y420 videos with an odd number of luma rows
//FIXME odd number of luma columns is not handled and they will be lost
static void Y420toY422_lastrow(UInt8 *o, UInt8 *yc, UInt8 *uc, UInt8 *vc, unsigned halfWidth)
{
	int x;
	for(x=0; x < halfWidth; x++)
	{
		int x4 = x*4, x2 = x*2;

		o[x4] = uc[x];
		o[x4+1] = yc[x2];
		o[x4+2] = vc[x];
		o[x4+3] = yc[x2+1];
	}
}

#define HandleLastRow(o, yc, uc, vc, halfWidth, height) if (unlikely(height & 1)) Y420toY422_lastrow(o, yc, uc, vc, halfWidth)

//Y420 Planar to Y422 Packed
//The only one anyone cares about, so implemented with SIMD

#include <emmintrin.h>

static FASTCALL void Y420toY422_sse2(AVFrame * picture, UInt8 *o, int outRB, unsigned width, unsigned height)
{
	UInt8	*yc = picture->data[0], *uc = picture->data[1], *vc = picture->data[2];
	int		rY = picture->linesize[0], rU = picture->linesize[1], rV = picture->linesize[2];
	int		y, x, halfwidth = width / 2 , halfheight = height / 2;
	int		vWidth = width / 32; 
	
	for (y = 0; y < halfheight; y++) {
		UInt8   * o2 = o + outRB,   * yc2 = yc + rY;
		__m128i * ov = (__m128i*)o, * ov2 = (__m128i*)o2, * yv = (__m128i*)yc, * yv2 = (__m128i*)yc2;
		__m128i * uv = (__m128i*)uc,* vv  = (__m128i*)vc;
		
		for (x = 0; x < vWidth; x++) {
			int x2 = x*2, x4 = x*4;

			__m128i	tmp_y = yv[x2], tmp_y3 = yv[x2+1],
					tmp_y2 = yv2[x2], tmp_y4 = yv2[x2+1],
					tmp_u = _mm_loadu_si128(&uv[x]), tmp_v = _mm_loadu_si128(&vv[x]),
					chroma_l = _mm_unpacklo_epi8(tmp_u, tmp_v),
					chroma_h = _mm_unpackhi_epi8(tmp_u, tmp_v);
			
			_mm_stream_si128(&ov[x4],   _mm_unpacklo_epi8(chroma_l, tmp_y)); 
			_mm_stream_si128(&ov[x4+1], _mm_unpackhi_epi8(chroma_l, tmp_y)); 
			_mm_stream_si128(&ov[x4+2], _mm_unpacklo_epi8(chroma_h, tmp_y3)); 
			_mm_stream_si128(&ov[x4+3], _mm_unpackhi_epi8(chroma_h, tmp_y3)); 
			
			_mm_stream_si128(&ov2[x4],  _mm_unpacklo_epi8(chroma_l, tmp_y2)); 
			_mm_stream_si128(&ov2[x4+1],_mm_unpackhi_epi8(chroma_l, tmp_y2));
			_mm_stream_si128(&ov2[x4+2],_mm_unpacklo_epi8(chroma_h, tmp_y4));
			_mm_stream_si128(&ov2[x4+3],_mm_unpackhi_epi8(chroma_h, tmp_y4));
		}

		for (x=vWidth * 16; x < halfwidth; x++) {
			int x4 = x*4, x2 = x*2;
			o2[x4] = o[x4] = uc[x];
			o[x4 + 1] = yc[x2];
			o2[x4 + 1] = yc2[x2];
			o2[x4 + 2] = o[x4 + 2] = vc[x];
			o[x4 + 3] = yc[x2 + 1];
			o2[x4 + 3] = yc2[x2 + 1];
		}			
		
		o += outRB*2;
		yc += rY*2;
		uc += rU;
		vc += rV;
	}

	HandleLastRow(o, yc, uc, vc, halfwidth, height);
}

static FASTCALL void Y420toY422_x86_scalar(AVFrame * picture, UInt8 * o, int outRB, unsigned width, unsigned height)
{
	UInt8	*yc = picture->data[0], *u = picture->data[1], *v = picture->data[2];
	int		rY = picture->linesize[0], rU = picture->linesize[1], rV = picture->linesize[2];
	int		halfheight = height / 2, halfwidth = width / 2;
	int		y, x;
	
	for (y = 0; y < halfheight; y ++) {
		UInt8 *o2 = o + outRB, *yc2 = yc + rY;
		
		for (x = 0; x < halfwidth; x++) {
			int x4 = x*4, x2 = x*2;
			o2[x4] = o[x4] = u[x];
			o[x4 + 1] = yc[x2];
			o2[x4 + 1] = yc2[x2];
			o2[x4 + 2] = o[x4 + 2] = v[x];
			o[x4 + 3] = yc[x2 + 1];
			o2[x4 + 3] = yc2[x2 + 1];
		}
		
		o += outRB*2;
		yc += rY*2;
		u += rU;
		v += rV;
	}

	HandleLastRow(o, yc, u, v, halfwidth, height);
}

//Y420+Alpha Planar to V408 (YUV 4:4:4+Alpha 32-bit packed)
//Could be fully unrolled to avoid x/2
static FASTCALL void YA420toV408(AVFrame *picture, UInt8 *o, int outRB, unsigned width, unsigned height)
{
	UInt8	*yc = picture->data[0], *u = picture->data[1], *v = picture->data[2], *a = picture->data[3];
	int		rY = picture->linesize[0], rU = picture->linesize[1], rV = picture->linesize[2], rA = picture->linesize[3];
	unsigned y, x;
	
	for (y = 0; y < height; y++) {
		for (x = 0; x < width; x++) {
			o[x*4] = u[x/2];
			o[x*4+1] = yc[x];
			o[x*4+2] = v[x/2];
			o[x*4+3] = a[x];
		}
		
		o += outRB;
		yc += rY;
		a += rA;
		if (y & 1) {
			u += rU;
			v += rV;
		}
	}
}

static FASTCALL void BGR24toRGB24(AVFrame *picture, UInt8 *baseAddr, int rowBytes, unsigned width, unsigned height)
{
	UInt8 *srcPtr = picture->data[0];
	int srcRB = picture->linesize[0];
	int x, y;
	
	for (y = 0; y < height; y++)
	{
		for (x = 0; x < width; x++)
		{
			unsigned x3 = x * 3;
			baseAddr[x3] = srcPtr[x3+2];
			baseAddr[x3+1] = srcPtr[x3+1];
			baseAddr[x3+2] = srcPtr[x3];
		}
		baseAddr += rowBytes;
		srcPtr += srcRB;
	}
}

//Native-endian XRGB32 to big-endian XRGB32
static FASTCALL void RGB32toRGB32(AVFrame *picture, UInt8 *baseAddr, int rowBytes, unsigned width, unsigned height)
{
	UInt8 *srcPtr = picture->data[0];
	int srcRB = picture->linesize[0];
	int y;

	for (y = 0; y < height; y++) {
#ifdef __BIG_ENDIAN__
		memcpy(baseAddr, srcPtr, width * 4);
#else
		UInt32 *oRow = (UInt32 *)baseAddr, *iRow = (UInt32 *)srcPtr;
		int x;
		for (x = 0; x < width; x++) {oRow[x] = EndianU32_NtoB(iRow[x]);}
#endif
		
		baseAddr += rowBytes;
		srcPtr += srcRB;
	}
}

static FASTCALL void RGBtoRGB(AVFrame *picture, UInt8 *baseAddr, int rowBytes, unsigned width, unsigned height, unsigned bytesPerPixel)
{
	UInt8 *srcPtr = picture->data[0];
	int srcRB = picture->linesize[0];
	int y;
	
	for (y = 0; y < height; y++) {
		memcpy(baseAddr, srcPtr, width * bytesPerPixel);
		
		baseAddr += rowBytes;
		srcPtr += srcRB;
	}
}

static FASTCALL void RGB24toRGB24(AVFrame *picture, UInt8 *baseAddr, int rowBytes, unsigned width, unsigned height)
{
	RGBtoRGB(picture, baseAddr, rowBytes, width, height, 3);
}

static FASTCALL void RGB16toRGB16(AVFrame *picture, UInt8 *baseAddr, int rowBytes, unsigned width, unsigned height)
{
	RGBtoRGB(picture, baseAddr, rowBytes, width, height, 2);
}

static FASTCALL void RGB16LEtoRGB16(AVFrame *picture, UInt8 *baseAddr, int rowBytes, unsigned width, unsigned height)
{
	UInt8 *srcPtr = picture->data[0];
	int srcRB = picture->linesize[0];
	int y, x;
	
	for (y = 0; y < height; y++) {
		UInt16 *oRow = (UInt16 *)baseAddr, *iRow = (UInt16 *)srcPtr;
		for (x = 0; x < width; x++) {oRow[x] = EndianU16_LtoB(iRow[x]);}
		
		baseAddr += rowBytes;
		srcPtr += srcRB;
	}
}

static FASTCALL void Y422toY422(AVFrame *picture, UInt8 *o, int outRB, unsigned width, unsigned height)
{
	UInt8	*yc = picture->data[0], *u = picture->data[1], *v = picture->data[2];
	int		rY = picture->linesize[0], rU = picture->linesize[1], rV = picture->linesize[2];
	int		x, y, halfwidth = width / 2;
	
	for (y = 0; y < height; y++) {
		for (x = 0; x < halfwidth; x++) {
			int x2 = x * 2, x4 = x * 4;
			o[x4] = u[x];
			o[x4 + 1] = yc[x2];
			o[x4 + 2] = v[x];
			o[x4 + 3] = yc[x2 + 1];
		}
		
		o += outRB;
		yc += rY;
		u += rU;
		v += rV;
	}
}

static FASTCALL void Y410toY422(AVFrame *picture, UInt8 *o, int outRB, unsigned width, unsigned height)
{
	UInt8	*yc = picture->data[0], *u = picture->data[1], *v = picture->data[2];
	int		rY = picture->linesize[0], rU = picture->linesize[1], rV = picture->linesize[2];
	int		x, y, halfwidth = width / 2;
	
	for (y = 0; y < height; y++) {
		for (x = 0; x < halfwidth; x++) {
			int x2 = x * 2, x4 = x * 4;
			o[x4] = u[x/2];
			o[x4 + 1] = yc[x2];
			o[x4 + 2] = v[x/2];
			o[x4 + 3] = yc[x2 + 1];
		}
		
		o += outRB;
		yc += rY;
		
		if (y % 4 == 3) {
			u += rU;
			v += rV;
		}
	}
}

static void ClearRGB(UInt8 *baseAddr, int rowBytes, unsigned width, unsigned height, int bytesPerPixel)
{
	int y;
	
	for (y = 0; y < height; y++) {
		memset(baseAddr, 0, width * bytesPerPixel);
		
		baseAddr += rowBytes;
	}
}

static FASTCALL void ClearRGB32(UInt8 *baseAddr, int rowBytes, unsigned width, unsigned height)
{
	ClearRGB(baseAddr, rowBytes, width, height, 4);
}

static FASTCALL void ClearRGB24(UInt8 *baseAddr, int rowBytes, unsigned width, unsigned height)
{
	ClearRGB(baseAddr, rowBytes, width, height, 3);
}

static FASTCALL void ClearRGB16(UInt8 *baseAddr, int rowBytes, unsigned width, unsigned height)
{
	ClearRGB(baseAddr, rowBytes, width, height, 2);
}

static FASTCALL void ClearV408(UInt8 *baseAddr, int rowBytes, unsigned width, unsigned height)
{
	int x, y;
	
	for (y = 0; y < height; y++)
	{
		for (x = 0; x < width; x++)
		{
			unsigned x4 = x * 4;
			baseAddr[x4]   = 0x80; //zero chroma
			baseAddr[x4+1] = 0x10; //black
			baseAddr[x4+2] = 0x80; 
			baseAddr[x4+3] = 0xEB; //opaque
		}
		baseAddr += rowBytes;
	}
}

static FASTCALL void ClearY422(UInt8 *baseAddr, int rowBytes, unsigned width, unsigned height)
{
	int x, y;
	
	for (y = 0; y < height; y++)
	{
		for (x = 0; x < width; x++)
		{
			unsigned x2 = x * 2;
			baseAddr[x2]   = 0x80; //zero chroma
			baseAddr[x2+1] = 0x10; //black
		}
		baseAddr += rowBytes;
	}
}

OSType ColorConversionDstForPixFmt(enum PixelFormat ffPixFmt)
{
	switch (ffPixFmt) {
		//case PIX_FMT_RGB555LE:
		//case PIX_FMT_RGB555BE:
		//	return k16BE555PixelFormat;
		case PIX_FMT_BGR24:
			return k24RGBPixelFormat; //XXX try k24BGRPixelFormat
		case PIX_FMT_RGB24:
			return k24RGBPixelFormat;
		case PIX_FMT_RGB32: // XXX not a specific pixel format, need LE & BE like 16-bit
			return k32ARGBPixelFormat;
		case PIX_FMT_YUV410P:
			return k2vuyPixelFormat;
		case PIX_FMT_YUV420P:
			return k2vuyPixelFormat; //disables "fast YUV" path
		case PIX_FMT_YUV422P:
			return k2vuyPixelFormat;
		default:
			return 0; // error
	}
}

int ColorConversionFindFor(ColorConversionFuncs *funcs, enum PixelFormat ffPixFmt, AVFrame *ffPicture, OSType qtPixFmt)
{
	switch (ffPixFmt) {
		case PIX_FMT_YUVJ420P:
		case PIX_FMT_YUV420P:
			funcs->clear = ClearY422;

#			if defined(__i386__) || defined(__x86_64__)
				// 32-bit or 64-bit Intel code
				//can't set this without the first real frame
				if (ffPicture) {
					if (ffPicture->linesize[0] % 16)
						funcs->convert = Y420toY422_x86_scalar;
					else
						funcs->convert = Y420toY422_sse2;
				}
#			else
#				error UNKNOWN ARCHITECTURE
#			endif
			break;
		case PIX_FMT_BGR24:
			funcs->clear = ClearRGB24;
			funcs->convert = BGR24toRGB24;
			break;
		case PIX_FMT_RGB32:
			funcs->clear = ClearRGB32;
			funcs->convert = RGB32toRGB32;
			break;
		case PIX_FMT_RGB24:
			funcs->clear = ClearRGB24;
			funcs->convert = RGB24toRGB24;
			break;
		//case PIX_FMT_RGB555LE:
		//	funcs->clear = ClearRGB16;
		//	funcs->convert = RGB16LEtoRGB16;
		//	break;
		//case PIX_FMT_RGB555BE:
		//	funcs->clear = ClearRGB16;
		//	funcs->convert = RGB16toRGB16;
		//	break;
		case PIX_FMT_YUV410P:
			funcs->clear = ClearY422;
			funcs->convert = Y410toY422;
			break;
		case PIX_FMT_YUVJ422P:
		case PIX_FMT_YUV422P:
			funcs->clear = ClearY422;
			funcs->convert = Y422toY422;
			break;
		case PIX_FMT_YUVA420P:
			funcs->clear = ClearV408;
			funcs->convert = YA420toV408;
			break;
		default:
			return paramErr;
	}
	
	return noErr;
}

