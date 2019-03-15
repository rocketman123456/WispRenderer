#define LIGHTS_REGISTER register(t2)
#include "util.hlsl"
#include "pbr_util.hlsl"
#include "material_util.hlsl"
#include "lighting.hlsl"

struct Vertex
{
	float3 pos;
	float2 uv;
	float3 normal;
	float3 tangent;
	float3 bitangent;
	float3 color;
};

struct Material
{
	float albedo_id;
	float normal_id;
	float roughness_id;
	float metalicness_id;

	MaterialData data;
};

struct Offset
{
    float material_idx;
    float idx_offset;
    float vertex_offset;
};

RWTexture2D<float4> output : register(u1); // xyz: reflection, a: shadow factor
ByteAddressBuffer g_indices : register(t1);
StructuredBuffer<Vertex> g_vertices : register(t3);
StructuredBuffer<Material> g_materials : register(t4);
StructuredBuffer<Offset> g_offsets : register(t5);

Texture2D g_textures[5000] : register(t8);
Texture2D gbuffer_albedo : register(t5008);
Texture2D gbuffer_normal : register(t5009);
Texture2D gbuffer_depth : register(t5010);
Texture2D skybox : register(t6);
TextureCube irradiance_map : register(t7);
SamplerState s0 : register(s0);

typedef BuiltInTriangleIntersectionAttributes MyAttributes;

struct HitInfo
{
	float3 color;
	unsigned int seed;
	float3 origin;
	unsigned int depth;
};

cbuffer CameraProperties : register(b0)
{
	float4x4 inv_view;
	float4x4 inv_projection;
	float4x4 inv_vp;

	float2 padding;
	float frame_idx;
	float intensity;
};

struct Ray
{
	float3 origin;
	float3 direction;
};

uint3 Load3x32BitIndices(uint offsetBytes)
{
	// Load first 2 indices
	return g_indices.Load3(offsetBytes);
}

// Retrieve hit world position.
float3 HitWorldPosition()
{
	return WorldRayOrigin() + RayTCurrent() * WorldRayDirection();
}

float4 TraceColorRay(float3 origin, float3 direction, unsigned int depth, unsigned int seed)
{
	if (depth >= MAX_RECURSION)
	{
		return skybox.SampleLevel(s0, SampleSphericalMap(direction), 0);
	}

	// Define a ray, consisting of origin, direction, and the min-max distance values
	RayDesc ray;
	ray.Origin = origin;
	ray.Direction = direction;
	ray.TMin = 0;
	ray.TMax = 10000.0;

	HitInfo payload = { float3(1, 1, 1), seed, origin, depth };

	// Trace the ray
	TraceRay(
		Scene,
		RAY_FLAG_NONE,
		~0, // InstanceInclusionMask
		0, // RayContributionToHitGroupIndex
		0, // MultiplierForGeometryContributionToHitGroupIndex
		0, // miss shader index
		ray,
		payload);

	return float4(payload.color, 1);
}

float3 unpack_position(float2 uv, float depth)
{
	// Get world space position
	const float4 ndc = float4(uv * 2.0 - 1.0, depth, 1.0);
	float4 wpos = mul(inv_vp, ndc);
	return (wpos.xyz / wpos.w).xyz;
}

#define M_PI 3.14159265358979

[shader("raygeneration")]
void RaygenEntry()
{
	uint rand_seed = initRand(DispatchRaysIndex().x + DispatchRaysIndex().y * DispatchRaysDimensions().x, frame_idx);

	// Texture UV coordinates [0, 1]
	float2 uv = float2(DispatchRaysIndex().xy) / float2(DispatchRaysDimensions().xy - 1);

	// Screen coordinates [0, resolution] (inverted y)
	int2 screen_co = DispatchRaysIndex().xy;

	// Get g-buffer information
	float4 albedo_roughness = gbuffer_albedo[screen_co];
	float4 normal_metallic = gbuffer_normal[screen_co];

	// Unpack G-Buffer
	float depth = gbuffer_depth[screen_co].x;
	float3 wpos = unpack_position(float2(uv.x, 1.f - uv.y), depth);
	float3 albedo = albedo_roughness.rgb;
	float roughness = albedo_roughness.w;
	float3 normal = normal_metallic.xyz;
	float metallic = normal_metallic.w;

	// Do lighting
	float3 cpos = float3(inv_view[0][3], inv_view[1][3], inv_view[2][3]);
	float3 V = normalize(cpos - wpos);

	float3 result = float3(0, 0, 0);

	nextRand(rand_seed);
	const float3 rand_dir = getUniformHemisphereSample(rand_seed, normal);
	const float cos_theta = cos(dot(rand_dir, normal));
	result = TraceColorRay(wpos + (normal * EPSILON), rand_dir, 0, rand_seed);
	//result = (TraceColorRay(wpos + (normal * EPSILON), rand_dir, 0, rand_seed) * cos_theta) * (albedo / PI);
	//result = (TraceColorRay(wpos + (normal * EPSILON), rand_dir, 0, rand_seed) * M_PI) * (1.0f / (2.0f * M_PI));

	result = clamp(result, 0, 10);

	// xyz: reflection, a: shadow factor
	if (frame_idx > 0 && !any(isnan(result)))
	{
		output[DispatchRaysIndex().xy] += float4(result, 1);
	}
	else
	{
		output[DispatchRaysIndex().xy] = float4(0, 0, 0, 0);
	}
}

//Reflections

float3 HitAttribute(float3 a, float3 b, float3 c, BuiltInTriangleIntersectionAttributes attr)
{
	float3 vertexAttribute[3];
	vertexAttribute[0] = a;
	vertexAttribute[1] = b;
	vertexAttribute[2] = c;

	return vertexAttribute[0] +
		attr.barycentrics.x * (vertexAttribute[1] - vertexAttribute[0]) +
		attr.barycentrics.y * (vertexAttribute[2] - vertexAttribute[0]);
}

[shader("closesthit")]
void ReflectionHit(inout HitInfo payload, in MyAttributes attr)
{
	// Calculate the essentials
	const Offset offset = g_offsets[InstanceID()];
	const Material material = g_materials[offset.material_idx];
	const float3 hit_pos = HitWorldPosition();
	const float index_offset = offset.idx_offset;
	const float vertex_offset = offset.vertex_offset;

	// Find first index location
	const uint index_size = 4;
    const uint indices_per_triangle = 3;
    const uint triangle_idx_stride = indices_per_triangle * index_size;

    uint base_idx = PrimitiveIndex() * triangle_idx_stride;
	base_idx += index_offset * 4; // offset the start

	uint3 indices = Load3x32BitIndices(base_idx);
	indices += float3(vertex_offset, vertex_offset, vertex_offset); // offset the start

	// Gather triangle vertices
	const Vertex v0 = g_vertices[indices.x];
	const Vertex v1 = g_vertices[indices.y];
	const Vertex v2 = g_vertices[indices.z];

	// Variables
	const float3 V = normalize(payload.origin - hit_pos);

	// Calculate actual "fragment" attributes.
	const float3 frag_pos = HitAttribute(v0.pos, v1.pos, v2.pos, attr);
	const float3 normal = normalize(HitAttribute(v0.normal, v1.normal, v2.normal, attr));
	const float3 tangent = HitAttribute(v0.tangent, v1.tangent, v2.tangent, attr);
	const float3 bitangent = HitAttribute(v0.bitangent, v1.bitangent, v2.bitangent, attr);

	float2 uv = HitAttribute(float3(v0.uv, 0), float3(v1.uv, 0), float3(v2.uv, 0), attr).xy;
	uv.y = 1.0f - uv.y;

	float mip_level = payload.depth+1;

	OutputMaterialData output_data = InterpretMaterialDataRT(material.data,
		g_textures[material.albedo_id],
		g_textures[material.normal_id],
		g_textures[material.roughness_id],
		g_textures[material.metalicness_id],
		mip_level,
		s0,
		uv);

	float3 albedo = output_data.albedo;
	float roughness = output_data.roughness;
	float metal = output_data.metallic;
	
	float3 N = normalize(mul(ObjectToWorld3x4(), float4(normal, 0)));
	float3 T = normalize(mul(ObjectToWorld3x4(), float4(tangent, 0)));
#define CALC_B
#ifndef CALC_B
	const float3 B = normalize(mul(ObjectToWorld3x4(), float4(bitangent, 0)));
#else
	T = normalize(T - dot(T, N) * N);
	float3 B = cross(N, T);
#endif
	const float3x3 TBN = float3x3(T, B, N);

	//float3 fN = N;
	float3 fN = normalize(mul(output_data.normal, TBN));
	if (dot(fN, V) <= 0.0f) fN = -fN;

	// Irradiance
	nextRand(payload.seed);
	const float3 rand_dir = getUniformHemisphereSample(payload.seed, N);
	const float cos_theta = cos(dot(rand_dir, normal));
	//float3 irradiance = TraceColorRay(hit_pos + (N * EPSILON), rand_dir, payload.depth + 1, payload.seed);
	//float3 irradiance = (TraceColorRay(hit_pos + (N * EPSILON), rand_dir, payload.depth + 1, payload.seed) * cos_theta) * (albedo / PI);
	float3 irradiance = (TraceColorRay(hit_pos + (N * EPSILON), rand_dir, payload.depth + 1, payload.seed) * M_PI) * (1.0f / (2.0f * M_PI));

	// Direct
	float3 reflect_dir = reflect(-V, fN);
	float3 reflection = TraceColorRay(hit_pos + N * EPSILON, reflect_dir, payload.depth + 1, payload.seed);

	const float3 F = F_SchlickRoughness(max(dot(fN, V), 0.0), 
		metal, 
		albedo, 
		roughness);
	float3 kS = F;
    float3 kD = 1.0 - kS;
    kD *= 1.0 - metal;

	float3 lighting = shade_pixel(hit_pos, V, 
		albedo, 
		metal, 
		roughness, 
		fN, 
		payload.seed, 
		payload.depth+2000);
	float3 specular = (reflection) * F;
	float3 diffuse = albedo * irradiance;
	float3 ambient = (kD * diffuse + specular);

	payload.color = ambient + lighting;
}

//Reflection skybox
[shader("miss")]
void ReflectionMiss(inout HitInfo payload)
{
	payload.color = (skybox.SampleLevel(s0, SampleSphericalMap(WorldRayDirection()), 0) * M_PI) * (1.0f / (2.0f * M_PI));
	//payload.color = float3(1, 1, 1);
}