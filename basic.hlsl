
//48 KiB; 48 * 1024 / sizeof(MeshNode)
//48 * 1024 / (4 * 4 * 4) = 48 * 1024 / 64 = 48 * 16 = 768
#define MAX_INSTANCES 768

struct VS_INPUT
{
	float3 pos : POSITION;
	float2 uv : TEXCOORD;
	float3 normal : NORMAL;
};

struct VS_OUTPUT
{
	float4 pos : SV_POSITION;
	float2 uv : TEXCOORD;
	float3 normal : NORMAL;
};

cbuffer CameraProperties : register(b0)
{
	float4x4 view;
	float4x4 projection;
	float4x4 inv_projection;
};

struct ObjectData
{
	float4x4 model;
};

cbuffer ObjectProperties : register(b1)
{
	ObjectData instances[MAX_INSTANCES];
};

VS_OUTPUT main_vs(VS_INPUT input, uint instid : SV_InstanceId)
{
	VS_OUTPUT output;

	float3 pos = input.pos;

	ObjectData inst = instances[instid];

	//TODO: Use precalculated MVP or at least VP
	float4x4 vm = mul(view, inst.model);
	float4x4 mvp = mul(projection, vm);
	
	output.pos =  mul(mvp, float4(pos, 1.0f));
	output.uv = input.uv;
	output.normal = normalize(mul(vm, input.normal)).xyz;

	return output;
}

struct PS_OUTPUT
{
	float4 albedo : SV_TARGET0;
	float4 normal : SV_TARGET1;
};

Texture2D material_albedo : register(t0);
SamplerState s0 : register(s0);

PS_OUTPUT main_ps(VS_OUTPUT input) : SV_TARGET
{
	PS_OUTPUT output;
	
	//float4 albedo = pow(material_albedo.Sample(s0, input.uv), 1.0f / 2.2f);
	float4 albedo = material_albedo.Sample(s0, input.uv);


	output.albedo = float4(albedo.xyz, 1.0f);
	output.normal = float4(input.normal, 1);
	return output;
}
