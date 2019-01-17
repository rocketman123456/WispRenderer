#pragma once

#include "../d3d12/d3d12_renderer.hpp"
#include "../d3d12/d3d12_functions.hpp"
#include "../d3d12/d3d12_constant_buffer_pool.hpp"
#include "d3d12_deferred_main.hpp"
#include "../d3d12/d3d12_structured_buffer_pool.hpp"
#include "../frame_graph/frame_graph.hpp"
#include "../scene_graph/camera_node.hpp"
#include "../d3d12/d3d12_rt_pipeline_registry.hpp"
#include "../d3d12/d3d12_root_signature_registry.hpp"
#include "../engine_registry.hpp"
#include "../util/math.hpp"

#include "../render_tasks/d3d12_deferred_main.hpp"
#include "../imgui_tools.hpp"

namespace wr
{
	struct RTHybridData
	{
		d3d12::DescriptorHeap* out_rt_heap;

		std::array<d3d12::ShaderTable*, d3d12::settings::num_back_buffers> out_raygen_shader_table = { nullptr, nullptr, nullptr };
		std::array<d3d12::ShaderTable*, d3d12::settings::num_back_buffers> out_miss_shader_table = { nullptr, nullptr, nullptr };
		std::array<d3d12::ShaderTable*, d3d12::settings::num_back_buffers> out_hitgroup_shader_table = { nullptr, nullptr, nullptr };

		d3d12::StateObject* out_state_object;
		d3d12::RootSignature* out_root_signature;
		D3D12ConstantBufferHandle* out_cb_camera_handle;

		d3d12::RenderTarget* out_deferred_main_rt;
	};

	namespace internal
	{

		inline void CreateShaderTables(d3d12::Device* device, RTHybridData& data, int frame_idx)
		{
			if (data.out_miss_shader_table[frame_idx])
			{
				d3d12::Destroy(data.out_miss_shader_table[frame_idx]);
			}
			if (data.out_hitgroup_shader_table[frame_idx])
			{
				d3d12::Destroy(data.out_hitgroup_shader_table[frame_idx]);
			}
			if (data.out_raygen_shader_table[frame_idx])
			{
				d3d12::Destroy(data.out_raygen_shader_table[frame_idx]);
			}

			// Raygen Shader Table
			{
				// Create Record(s)
				UINT shader_record_count = 1;
				auto shader_identifier_size = d3d12::GetShaderIdentifierSize(device, data.out_state_object);
				auto shader_identifier = d3d12::GetShaderIdentifier(device, data.out_state_object, "RaygenEntry");

				auto shader_record = d3d12::CreateShaderRecord(shader_identifier, shader_identifier_size);

				// Create Table
				data.out_raygen_shader_table[frame_idx] = d3d12::CreateShaderTable(device, shader_record_count, shader_identifier_size);
				d3d12::AddShaderRecord(data.out_raygen_shader_table[frame_idx], shader_record);
			}

			// Miss Shader Table
			{
				// Create Record(s)
				UINT shader_record_count = 2;
				auto shader_identifier_size = d3d12::GetShaderIdentifierSize(device, data.out_state_object);

				auto shadow_miss_identifier = d3d12::GetShaderIdentifier(device, data.out_state_object, "MissEntry");
				auto shadow_miss_record = d3d12::CreateShaderRecord(shadow_miss_identifier, shader_identifier_size);

				auto reflection_miss_identifier = d3d12::GetShaderIdentifier(device, data.out_state_object, "ReflectionMiss");
				auto reflection_miss_record = d3d12::CreateShaderRecord(reflection_miss_identifier, shader_identifier_size);

				// Create Table
				data.out_miss_shader_table[frame_idx] = d3d12::CreateShaderTable(device, shader_record_count, shader_identifier_size);
				d3d12::AddShaderRecord(data.out_miss_shader_table[frame_idx], shadow_miss_record);
				d3d12::AddShaderRecord(data.out_miss_shader_table[frame_idx], reflection_miss_record);
			}

			// Hit Group Shader Table
			{
				// Create Record(s)
				UINT shader_record_count = 2;
				auto shader_identifier_size = d3d12::GetShaderIdentifierSize(device, data.out_state_object);

				auto shadow_hit_identifier = d3d12::GetShaderIdentifier(device, data.out_state_object, "MyHitGroup");
				auto shadow_hit_record = d3d12::CreateShaderRecord(shadow_hit_identifier, shader_identifier_size);

				auto reflection_hit_identifier = d3d12::GetShaderIdentifier(device, data.out_state_object, "ReflectionHitGroup");
				auto reflection_hit_record = d3d12::CreateShaderRecord(reflection_hit_identifier, shader_identifier_size);

				// Create Table
				data.out_hitgroup_shader_table[frame_idx] = d3d12::CreateShaderTable(device, shader_record_count, shader_identifier_size);
				d3d12::AddShaderRecord(data.out_hitgroup_shader_table[frame_idx], shadow_hit_record);
				d3d12::AddShaderRecord(data.out_hitgroup_shader_table[frame_idx], reflection_hit_record);
			}
		}

		inline void SetupRTHybridTask(RenderSystem & render_system, FrameGraph & fg, RenderTaskHandle & handle)
		{
			auto& n_render_system = static_cast<D3D12RenderSystem&>(render_system);
			auto& device = n_render_system.m_device;
			auto& data = fg.GetData<RTHybridData>(handle);
			auto n_render_target = fg.GetRenderTarget<d3d12::RenderTarget>(handle);

			d3d12::SetName(n_render_target, L"Raytracing Target");

			// Create descriptor heap
			d3d12::desc::DescriptorHeapDesc heap_desc;
			heap_desc.m_num_descriptors = 600; // FIXME: 600
			heap_desc.m_type = DescriptorHeapType::DESC_HEAP_TYPE_CBV_SRV_UAV;
			heap_desc.m_shader_visible = true;
			heap_desc.m_versions = d3d12::settings::num_back_buffers;
			data.out_rt_heap = d3d12::CreateDescriptorHeap(device, heap_desc);
			SetName(data.out_rt_heap, L"Raytracing Task Descriptor Heap");

			// Get AS build data
			auto& as_build_data = fg.GetPredecessorData<wr::ASBuildData>();
			// Bind AS (supposed to be in frame_idx loop, but only requires to be in frame_idx 0 as of right now)
			auto as_cpu_handle = d3d12::GetCPUHandle(as_build_data.out_rt_heap, 0);
			d3d12::CreateUAVFromSpecificRTV(n_render_target, as_cpu_handle, 0, n_render_target->m_create_info.m_rtv_formats[0]);

			// Versioning
			for (int frame_idx = 0; frame_idx < d3d12::settings::num_back_buffers; ++frame_idx)
			{
				// Bind output texture
				auto cpu_handle = d3d12::GetCPUHandle(data.out_rt_heap, frame_idx);
				d3d12::CreateUAVFromRTV(n_render_target, cpu_handle, 1, n_render_target->m_create_info.m_rtv_formats.data());

				// Bind g-buffers (albedo, normal, depth)
				cpu_handle = d3d12::GetCPUHandle(data.out_rt_heap, frame_idx, d3d12::settings::hybrid_g_buffer_offset);
				auto deferred_main_rt = data.out_deferred_main_rt = static_cast<d3d12::RenderTarget*>(fg.GetPredecessorRenderTarget<DeferredMainTaskData>());
				d3d12::CreateSRVFromRTV(deferred_main_rt, cpu_handle, 2, deferred_main_rt->m_create_info.m_rtv_formats.data());
				d3d12::CreateSRVFromDSV(deferred_main_rt, cpu_handle);
			}

			// Camera constant buffer
			data.out_cb_camera_handle = static_cast<D3D12ConstantBufferHandle*>(n_render_system.m_raytracing_cb_pool->Create(sizeof(temp::RTHybridCamera_CBData)));

			// Pipeline State Object
			auto& rt_registry = RTPipelineRegistry::Get();
			data.out_state_object = static_cast<D3D12StateObject*>(rt_registry.Find(state_objects::rt_hybrid_state_object))->m_native;

			// Root Signature
			auto& rs_registry = RootSignatureRegistry::Get();
			data.out_root_signature = static_cast<D3D12RootSignature*>(rs_registry.Find(root_signatures::rt_hybrid_global))->m_native;

			// Create Shader Tables
			CreateShaderTables(device, data, 0);
			CreateShaderTables(device, data, 1);
			CreateShaderTables(device, data, 2);
		}

		inline void ExecuteRTHybridTask(RenderSystem & render_system, FrameGraph & fg, SceneGraph & scene_graph, RenderTaskHandle & handle)
		{
			auto& n_render_system = static_cast<D3D12RenderSystem&>(render_system);
			auto window = n_render_system.m_window.value();
			auto device = n_render_system.m_device;
			auto cmd_list = fg.GetCommandList<d3d12::CommandList>(handle);
			auto& data = fg.GetData<RTHybridData>(handle);
			auto& as_build_data = fg.GetPredecessorData<wr::ASBuildData>();

			cmd_list->m_native->ResourceBarrier(1, &CD3DX12_RESOURCE_BARRIER::UAV(as_build_data.out_tlas.m_native));

			if (n_render_system.m_render_window.has_value())
			{
				auto frame_idx = n_render_system.GetFrameIdx();

				// Get light buffer
				if (static_cast<D3D12StructuredBufferHandle*>(scene_graph.GetLightBuffer())->m_native->m_states[frame_idx] != ResourceState::NON_PIXEL_SHADER_RESOURCE)
				{
					static_cast<D3D12StructuredBufferPool*>(scene_graph.GetLightBuffer()->m_pool)->SetBufferState(scene_graph.GetLightBuffer(), ResourceState::NON_PIXEL_SHADER_RESOURCE);
				}
				auto cpu_handle = d3d12::GetCPUHandle(as_build_data.out_rt_heap, 0, 2);
				d3d12::CreateSRVFromStructuredBuffer(static_cast<D3D12StructuredBufferHandle*>(scene_graph.GetLightBuffer())->m_native, cpu_handle, frame_idx);

				// Update material data
				n_render_system.m_raytracing_material_sb_pool->Update(as_build_data.out_sb_material_handle, (void*) as_build_data.out_materials.data(), sizeof(temp::RayTracingMaterial_CBData) * d3d12::settings::num_max_rt_materials, 0);

				// Update camera cb
				static int fc = -10;
				if (n_render_system.clear_path)
				{
					fc = -1;
					n_render_system.clear_path = false;
				}

				n_render_system.temp_rough = fc;
				fc++;

				auto camera = scene_graph.GetActiveCamera();
				temp::RTHybridCamera_CBData cam_data;
				cam_data.m_inverse_view = DirectX::XMMatrixInverse(nullptr, camera->m_view );
				cam_data.m_inverse_projection = DirectX::XMMatrixInverse(nullptr, camera->m_projection);
				cam_data.m_inv_vp = DirectX::XMMatrixInverse(nullptr, camera->m_view * camera->m_projection);
				cam_data.m_roughness = fc;
				cam_data.m_intensity = n_render_system.temp_intensity;
				n_render_system.m_camera_pool->Update(data.out_cb_camera_handle, sizeof(temp::RTHybridCamera_CBData), 0, frame_idx, (std::uint8_t*)&cam_data); // FIXME: Uhh wrong pool?

				// Transition depth to NON_PIXEL_RESOURCE
				d3d12::TransitionDepth(cmd_list, data.out_deferred_main_rt, ResourceState::DEPTH_WRITE, ResourceState::NON_PIXEL_SHADER_RESOURCE);
				
				// Bind last essentials
				d3d12::BindRaytracingPipeline(cmd_list, data.out_state_object, d3d12::GetRaytracingType(device) == RaytracingType::FALLBACK);

				d3d12::BindDescriptorHeap(cmd_list, as_build_data.out_rt_heap, as_build_data.out_rt_heap->m_create_info.m_type, 0, d3d12::GetRaytracingType(device) == RaytracingType::FALLBACK);

				auto gpu_handle = d3d12::GetGPUHandle(as_build_data.out_rt_heap, 0); // here
				d3d12::BindComputeDescriptorTable(cmd_list, gpu_handle, 0);
				d3d12::BindComputeConstantBuffer(cmd_list, data.out_cb_camera_handle->m_native, 2, frame_idx);

				if (d3d12::GetRaytracingType(device) == RaytracingType::NATIVE)
				{
					d3d12::BindComputeShaderResourceView(cmd_list, as_build_data.out_tlas.m_native, 1);
				}
				else if (d3d12::GetRaytracingType(device) == RaytracingType::FALLBACK)
				{
					cmd_list->m_native_fallback->SetTopLevelAccelerationStructure(0, as_build_data.out_tlas.m_fallback_tlas_ptr);
				}

				d3d12::BindComputeShaderResourceView(cmd_list, as_build_data.out_scene_vb->m_buffer, 3);

				// Dispatch hybrid ray tracing rays
				d3d12::DispatchRays(cmd_list, data.out_hitgroup_shader_table[frame_idx], data.out_miss_shader_table[frame_idx], data.out_raygen_shader_table[frame_idx], window->GetWidth(), window->GetHeight(), 1);

				// Transition depth back to DEPTH_WRITE
				d3d12::TransitionDepth(cmd_list, data.out_deferred_main_rt, ResourceState::NON_PIXEL_SHADER_RESOURCE, ResourceState::DEPTH_WRITE);
			}
		}

	} /* internal */

	inline void AddRTHybridTask(FrameGraph& fg)
	{
		RenderTargetProperties rt_properties
		{
			false,
			std::nullopt,
			std::nullopt,
			ResourceState::UNORDERED_ACCESS,
			ResourceState::COPY_SOURCE,
			false,
			Format::UNKNOWN,
			{ Format::R8G8B8A8_UNORM },
			1,
			true,
			true
		};
		//RTHybridData
		RenderTaskDesc desc;
		desc.m_setup_func = [] (RenderSystem& rs, FrameGraph& fg, RenderTaskHandle handle, bool)
		{
			internal::SetupRTHybridTask(rs, fg, handle);
		};
		desc.m_execute_func = [] (RenderSystem& rs, FrameGraph& fg, SceneGraph& sg, RenderTaskHandle handle)
		{
			internal::ExecuteRTHybridTask(rs, fg, sg, handle);
		};
		desc.m_destroy_func = [] (FrameGraph&, RenderTaskHandle, bool)
		{
			// Nothing to destroy
		};
		desc.m_name = "Hybrid raytracing";
		desc.m_properties = rt_properties;
		desc.m_type = RenderTaskType::COMPUTE;
		desc.m_allow_multithreading = true;

		fg.AddTask<RTHybridData>(desc);
	}

} /* wr */
