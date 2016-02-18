﻿//
// Kino/Obscurance - SSAO (screen-space ambient obscurance) effect for Unity
//
// Copyright (C) 2016 Keijiro Takahashi
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//
Shader "Hidden/Kino/Obscurance"
{
    Properties
    {
        _MainTex("", 2D) = ""{}
        _AOTex("", 2D) = ""{}
        _BlurTex("", 2D) = ""{}
    }
    CGINCLUDE

    #include "UnityCG.cginc"

    #pragma multi_compile _METHOD_SIMPLE _METHOD_NORMAL
    #pragma multi_compile _ _COUNT_LOW _COUNT_MEDIUM
    #pragma multi_compile _BLUR_3TAP _BLUR_5TAP

    sampler2D _MainTex;
    float2 _MainTex_TexelSize;

    sampler2D _AOTex;
    float2 _AOTex_TexelSize;

    sampler2D _BlurTex;
    float2 _BlurTex_TexelSize;

    sampler2D _CameraDepthNormalsTexture;

    half _Intensity;
    half _Contrast;
    float _Radius;
    float2 _BlurVector;

    static const float kFallOffDist = 100;

    #if _COUNT_LOW
    static const int _SampleCount = 6;
    #elif _COUNT_MEDIUM
    static const int _SampleCount = 12;
    #else
    int _SampleCount; // given as a uniform
    #endif

    float UVRandom(float2 uv, float dx, float dy)
    {
        uv += float2(dx, dy + _Time.x * 0);
        return frac(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453);
    }

    float gradientNoise(float2 uv)
    {
        float f = dot(float2(0.06711056f, 0.00583715f), uv);
        return frac(52.9829189f * frac(f));
    }

    float3 RandomVectorSphere(float2 uv, float index)
    {
        // Uniformaly distributed points
        // http://mathworld.wolfram.com/SpherePointPicking.html
        float u = UVRandom(0, 0, index) * 2 - 1;
        float gn = gradientNoise(uv / _MainTex_TexelSize);
        float theta = (UVRandom(0, 1, index) + gn) * UNITY_PI * 2;
        float u2 = sqrt(1 - u * u);
        float3 v = float3(u2 * cos(theta), u2 * sin(theta), u);
        // Adjustment for distance distribution
        float l = index / _SampleCount;
        return v * lerp(0.1, 1.0, pow(l, 1.0 / 3));
    }

    float2 RandomVectorDisc(float2 uv, float index)
    {
        float gn = gradientNoise(uv / _MainTex_TexelSize);
        float sn, cs;
        sincos((UVRandom(0, 0, index) + gn) * UNITY_PI * 2, sn, cs);
        float l = lerp(0.1, 1.0, index / _SampleCount);
        return float2(sn, cs) * l;
    }

    float SampleDepth(float2 uv)
    {
        float4 cdn = tex2D(_CameraDepthNormalsTexture, uv);
        return DecodeFloatRG(cdn.zw) * _ProjectionParams.z;
    }

    float3 SampleNormal(float2 uv)
    {
        float4 cdn = tex2D(_CameraDepthNormalsTexture, uv);
        float3 normal = DecodeViewNormalStereo(cdn);
        normal.z *= -1;
        return normal;
    }

    float SampleDepthNormal(float2 uv, out float3 normal)
    {
        float4 cdn = tex2D(_CameraDepthNormalsTexture, uv);
        normal = DecodeViewNormalStereo(cdn);
        normal.z *= -1;
        return DecodeFloatRG(cdn.zw) * _ProjectionParams.z;
    }

    float3 ReconstructWorldPos(float2 uv, float depth, float2 p11_22, float2 p13_31)
    {
        return float3((uv * 2 - 1 - p13_31) / p11_22, 1) * depth;
    }

    half CompareNormal(half3 d1, half3 d2)
    {
        return pow((dot(d1, d2) + 1) * 0.5, 80);
    }

    half3 CombineObscurance(half3 src, half3 ao)
    {
        return lerp(src, 0, ao);
    }

    float CalculateObscurance(float2 uv)
    {
        // Parameters used for coordinate conversion
        float3x3 proj = (float3x3)unity_CameraProjection;
        float2 p11_22 = float2(unity_CameraProjection._11, unity_CameraProjection._22);
        float2 p13_31 = float2(unity_CameraProjection._13, unity_CameraProjection._23);

        // View space normal and depth
        float3 norm_o;
        float depth_o = SampleDepthNormal(uv, norm_o);

        // Early-out case
        if (depth_o > kFallOffDist) return 0;

        // Reconstruct the view-space position.
        float3 pos_o = ReconstructWorldPos(uv, depth_o, p11_22, p13_31);

        float ao = 0.0;
#if _METHOD_NORMAL
        for (int s = 0; s < _SampleCount; s++)
        {
            // Sampling point
            float3 v1 = RandomVectorSphere(uv, s);
            v1 = faceforward(v1, -norm_o, v1);
            float3 pos_s = pos_o + v1 * _Radius;

            // Re-project the sampling point
            float3 pos_sc = mul(proj, pos_s);
            float2 uv_s = (pos_sc.xy / pos_s.z + 1) * 0.5;

            // Sample linear depth at the sampling point.
            float depth_s = SampleDepth(uv_s);

            // Get the distance.
            float3 pos_s2 = ReconstructWorldPos(uv_s, depth_s, p11_22, p13_31);
            float3 v = pos_s2 - pos_o;

            // Calculate the obscurance value.
            ao += max(dot(v, norm_o) - 0.01, 0) / (dot(v, v) + 0.001);
        }
#else
        for (int s = 0; s < _SampleCount / 2; s++)
        {
            // Sampling point
            float2 v_r = RandomVectorDisc(uv, s) * _Radius;
            float2 uv_s1 = uv + v_r / depth_o;
            float2 uv_s2 = uv - v_r / depth_o;

            // Depth at the sampling point
            float depth_s1 = SampleDepth(uv_s1);
            float depth_s2 = SampleDepth(uv_s2);

            // World position
            float3 wp_s1 = ReconstructWorldPos(uv_s1, depth_s1, p11_22, p13_31);
            float3 wp_s2 = ReconstructWorldPos(uv_s2, depth_s2, p11_22, p13_31);

            float3 v_s1 = normalize(wp_s1 - pos_o);
            float3 v_s2 = normalize(wp_s2 - pos_o);

            float3 dv1 = min(0, dot(v_s1, norm_o));
            v_s1 = normalize(v_s1 - norm_o * dv1);

            float3 dv2 = min(0, dot(v_s2, norm_o));
            v_s2 = normalize(v_s2 - norm_o * dv2);

            float3 v_h = normalize(v_s1 + v_s2);

            float a = 1 - acos(dot(v_s1, v_h)) * 2 / UNITY_PI;

            a *= dot(v_h, norm_o) > 0.01;
            a *= saturate(2 - distance(pos_o, wp_s1) / _Radius);
            a *= saturate(2 - distance(pos_o, wp_s2) / _Radius);

            ao += a * 8;
        }
#endif

        // Calculate the final AO value.
        float falloff = 1.0 - depth_o / kFallOffDist;
        return pow(ao * _Intensity * falloff / _SampleCount, _Contrast);
    }

    half3 SeparableBlur(float2 uv, float2 delta)
    {
        half3 n0 = SampleNormal(uv);
#ifdef _BLUR_3TAP
        half2 uv1 = uv - delta;
        half2 uv2 = uv + delta;

        half w1 = CompareNormal(n0, SampleNormal(uv1));
        half w2 = CompareNormal(n0, SampleNormal(uv2));

        half3 s = tex2D(_BlurTex, uv) * 2;
        s += tex2D(_BlurTex, uv1) * w1;
        s += tex2D(_BlurTex, uv2) * w2;

        return s / (2 + w1 + w2);
#else
        half2 uv1 = uv - delta * 2;
        half2 uv2 = uv - delta;
        half2 uv3 = uv + delta;
        half2 uv4 = uv + delta * 2;

        half w1 = CompareNormal(n0, SampleNormal(uv1));
        half w2 = CompareNormal(n0, SampleNormal(uv2));
        half w3 = CompareNormal(n0, SampleNormal(uv3));
        half w4 = CompareNormal(n0, SampleNormal(uv4));

        half3 s = tex2D(_BlurTex, uv) * 3;
        s += tex2D(_BlurTex, uv1) * w1;
        s += tex2D(_BlurTex, uv2) * w2 * 2;
        s += tex2D(_BlurTex, uv3) * w3 * 2;
        s += tex2D(_BlurTex, uv4) * w4;

        return s / (3 + w1 + w2 *2 + w3 *2 + w4);
#endif
    }

    half4 frag_ao_combined(v2f_img i) : SV_Target
    {
        half4 src = tex2D(_MainTex, i.uv);
        half ao = CalculateObscurance(i.uv);
        return half4(CombineObscurance(src.rgb, ao), src.a);
    }

    half4 frag_ao(v2f_img i) : SV_Target
    {
        return CalculateObscurance(i.uv);
    }

    half4 frag_combine(v2f_img i) : SV_Target
    {
        half4 src = tex2D(_MainTex, i.uv);
        half ao = tex2D(_AOTex, i.uv);
        return half4(CombineObscurance(src.rgb, ao), src.a);
    }

    half4 frag_blur(v2f_img i) : SV_Target
    {
        float2 delta = _BlurTex_TexelSize.xy * _BlurVector;
        return half4(SeparableBlur(i.uv, delta), 0);
    }

    half4 frag_blur_combine(v2f_img i) : SV_Target
    {
        half4 src = tex2D(_MainTex, i.uv);
        float2 delta = _BlurTex_TexelSize.xy * _BlurVector;
        half ao = SeparableBlur(i.uv, delta);
        return half4(CombineObscurance(src.rgb, ao), src.a);
    }

    ENDCG
    SubShader
    {
        Pass
        {
            ZTest Always Cull Off ZWrite Off
            CGPROGRAM
            #pragma vertex vert_img
            #pragma fragment frag_ao_combined
            #pragma target 3.0
            ENDCG
        }
        Pass
        {
            ZTest Always Cull Off ZWrite Off
            CGPROGRAM
            #pragma vertex vert_img
            #pragma fragment frag_ao
            #pragma target 3.0
            ENDCG
        }
        Pass
        {
            ZTest Always Cull Off ZWrite Off
            CGPROGRAM
            #pragma vertex vert_img
            #pragma fragment frag_combine
            #pragma target 3.0
            ENDCG
        }
        Pass
        {
            ZTest Always Cull Off ZWrite Off
            CGPROGRAM
            #pragma vertex vert_img
            #pragma fragment frag_blur
            #pragma target 3.0
            ENDCG
        }
        Pass
        {
            ZTest Always Cull Off ZWrite Off
            CGPROGRAM
            #pragma vertex vert_img
            #pragma fragment frag_blur_combine
            #pragma target 3.0
            ENDCG
        }
    }
}
