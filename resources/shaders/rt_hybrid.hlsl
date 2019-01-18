#include "pbr_util.hlsl"

#define MAX_RECURSION 1

struct Light
{
	float3 pos;			//Position in world space for spot & point
	float radius;		//Radius for point, height for spot

	float3 color;		//Color
	uint tid;			//Type id; light_type_x

	float3 dir;			//Direction for spot & directional
	float angle;		//Angle for spot; in radians
};

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
	float idx_offset;
	float vertex_offset;
	float albedo_id;
	float normal_id;
	float roughness_id;
	float metalicness_id;
};

RWTexture2D<float4> gOutput : register(u0);
RaytracingAccelerationStructure Scene : register(t0, space0);
ByteAddressBuffer g_indices : register(t1);
StructuredBuffer<Light> lights : register(t2);
StructuredBuffer<Vertex> g_vertices : register(t3);
StructuredBuffer<Material> g_materials : register(t4);

Texture2D g_textures[20] : register(t5);
Texture2D gbuffer_albedo : register(t26);
Texture2D gbuffer_normal : register(t27);
Texture2D gbuffer_depth : register(t28);
SamplerState s0 : register(s0);

typedef BuiltInTriangleIntersectionAttributes MyAttributes;
struct ShadowHitInfo
{
	bool shadow_hit;
};

struct ReflectionHitInfo
{
	float3 origin;
	float3 color;
};

cbuffer CameraProperties : register(b0)
{
	float4x4 inv_view;
	float4x4 inv_projection;
	float4x4 inv_vp;

	float2 padding;
	float pbr_roughness;
	float intensity;
};

struct Ray
{
	float3 origin;
	float3 direction;
};

static const uint light_type_point = 0;
static const uint light_type_directional = 1;
static const uint light_type_spot = 2;

//TODO: Replace sky_color by sampling an envmap
static const float3 sky_color = float3(0x1E / 255.f, 0x90 / 255.f, 0xFF / 255.f);

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

bool TraceShadowRay(float3 origin, float3 direction, float t_max)
{
	ShadowHitInfo payload = { false };

	// Define a ray, consisting of origin, direction, and the min-max distance values
	RayDesc ray;
	ray.Origin = origin;
	ray.Direction = direction;
	ray.TMin = 0.0000;
	ray.TMax = t_max;

	// Trace the ray
	TraceRay(
		Scene,
		// TODO: Change flags if transparency is added
		RAY_FLAG_FORCE_OPAQUE // Treat all geometry as opaque.
		| RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH, // Accept first hit
		~0, // InstanceInclusionMask
		0, // RayContributionToHitGroupIndex
		1, // MultiplierForGeometryContributionToHitGroupIndex
		0, // miss shader index
		ray,
		payload);

	return payload.shadow_hit;
}

float3 TraceReflectionRay(float3 origin, float3 direction)
{
	float epsilon = 0.005;

	ReflectionHitInfo payload = { origin + direction * epsilon, float3(0, 0, 1) };

	// Define a ray, consisting of origin, direction, and the min-max distance values
	RayDesc ray;
	ray.Origin = origin;
	ray.Direction = direction;
	ray.TMin = epsilon;
	ray.TMax = 10000.0;

	// Trace the ray
	TraceRay(
		Scene,
		RAY_FLAG_NONE,
		//RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH
		// RAY_FLAG_CULL_BACK_FACING_TRIANGLES,
		~0, // InstanceInclusionMask
		1, // RayContributionToHitGroupIndex
		1, // MultiplierForGeometryContributionToHitGroupIndex
		1, // miss shader index
		ray,
		payload);

	return payload.color;
}

float3 unpack_position(float2 uv, float depth)
{
	// Get world space position
	const float4 ndc = float4(uv * 2.0 - 1.0, depth, 1.0);
	float4 wpos = mul(inv_vp, ndc);
	return (wpos.xyz / wpos.w).xyz;
}

float calc_attenuation(float r, float d)
{
	return 1.0f - smoothstep(r * 0, r, d);
}

float3 ShadeLight(float3 wpos, float3 V, float3 albedo, float3 normal, float roughness, float metal, Light light)
{
	uint tid = light.tid & 3;

	//Light direction (constant with directional, position dependent with other)
	float3 L = (lerp(light.pos - wpos, -light.dir, tid == light_type_directional));
	float light_dist = length(L);
	L /= light_dist;

	float range = light.radius;
	const float attenuation = calc_attenuation(range, light_dist);

	//Spot intensity (only used with spot; but always calculated)
	float min_cos = cos(light.angle);
	float max_cos = lerp(min_cos, 1, 0.5f);
	float cos_angle = dot(light.dir, -L);
	float spot_intensity = lerp(smoothstep(min_cos, max_cos, cos_angle), 1, tid != light_type_spot);

	// Calculate radiance
	const float3 radiance = (intensity * spot_intensity * light.color) * attenuation;

	float3 lighting = BRDF(L, V, normal, metal, roughness, albedo, radiance, light.color);

	// Check if pixel is shaded
	float epsilon = 0.005; // Hard-coded; use depth buffer to get depth value in linear space and use that to determine the epsilon (to minimize precision errors)
	float3 origin = wpos + normal * 0.005;
	float t_max = lerp(light_dist, 10000.0, tid == light_type_directional);
	bool is_shadow = TraceShadowRay(origin, L, t_max);

	lighting = lerp(lighting, float3(0, 0, 0), is_shadow);

	return lighting;
}

float3 ShadePixel(float3 vpos, float3 V, float3 albedo, float3 normal, float roughness, float metal)
{
	uint light_count = lights[0].tid >> 2;	//Light count is stored in 30 upper-bits of first light

	float ambient = 0.1f;
	float3 res = float3(ambient, ambient, ambient);

	for (uint i = 0; i < light_count; i++)
	{
		res += ShadeLight(vpos, V, albedo, normal, roughness, metal, lights[i]);
	}

	return res * albedo;
}

float3 DoReflection(float3 wpos, float3 normal, float roughness, float metallic, float3 albedo)
{

	// Get direction to camera

	float3 cpos = float3(inv_view[0][3], inv_view[1][3], inv_view[2][3]);

	float3 cdir = wpos - cpos;
	float cdist = length(cdir);
	cdir /= cdist;

	// Calculate ray info

	float3 reflected = reflect(cdir, normal);

	// Shoot reflection ray

	float3 reflection = TraceReflectionRay(wpos, reflected);

	// TODO: Roughness

	// TODO: Calculate reflection combined with fresnel

	float cosTheta = max(-dot(normal, cdir), 0);
	float fresnel = pow(1 - cosTheta, 5 / (4.9 * metallic + 0.1));

	float3 fresnel_reflection = lerp(albedo, reflection, 0.5f);

	return albedo; // Set to fresnel_reflection for reflections
}

[shader("raygeneration")]
void RaygenEntry()
{
	// Texture UV coordinates [0, 1]
	float2 uv = float2(DispatchRaysIndex().xy) / float2(DispatchRaysDimensions().xy - 1);

	// Screen coordinates [0, resolution] (inverted y)
	int2 screen_co = DispatchRaysIndex().xy;
	screen_co.y = (DispatchRaysDimensions().y - screen_co.y - 1);

	// Get g-buffer information
	float4 albedo_roughness = gbuffer_albedo[screen_co];
	float4 normal_metallic = gbuffer_normal[screen_co];

	// Unpack G-Buffer
	float depth = gbuffer_depth[screen_co].x;
	float3 wpos = unpack_position(uv, depth);
	float3 albedo = albedo_roughness.rgb;
	float roughness = albedo_roughness.w;
	float3 normal = normal_metallic.xyz;
	float metallic = normal_metallic.w;

	if (length(normal) == 0)		//TODO: Could be optimized by only marking pixels that need lighting, but that would require execute rays indirect
	{
		gOutput[DispatchRaysIndex().xy] = float4(sky_color, 1);
		return;
	}

	// Do lighting
	float3 cpos = float3(inv_view[0][3], inv_view[1][3], inv_view[2][3]);
	float3 V = normalize(cpos - wpos);

	float3 lighting = ShadePixel(wpos, V, albedo, normal, roughness, metallic);

	gOutput[DispatchRaysIndex().xy] = float4(lighting, 1);

}

//Shadows
[shader("closesthit")]
void ShadowHit(inout ShadowHitInfo payload, in MyAttributes attr)
{
	payload.shadow_hit = true;
}

//Shadows
[shader("miss")]
void ShadowMiss(inout ShadowHitInfo payload)
{
	payload.shadow_hit = false;
}

