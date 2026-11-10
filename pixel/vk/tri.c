// Offscreen Vulkan triangle on the Pixel's PowerVR driver; writes /data/local/tmp/tri.ppm
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "vert.h"
#include "frag.h"
#define W 512
#define H 512
#define CK(x) do{VkResult r_=(x); if(r_){printf("FAIL %s = %d line %d\n",#x,r_,__LINE__); exit(1);}}while(0)
static uint32_t memtype(VkPhysicalDevice pd,uint32_t bits,VkMemoryPropertyFlags f){
  VkPhysicalDeviceMemoryProperties m; vkGetPhysicalDeviceMemoryProperties(pd,&m);
  for(uint32_t i=0;i<m.memoryTypeCount;i++) if((bits&(1u<<i))&&(m.memoryTypes[i].propertyFlags&f)==f) return i;
  printf("no memtype\n"); exit(1);
}
int main(void){
  VkApplicationInfo ai={VK_STRUCTURE_TYPE_APPLICATION_INFO,0,"tri",1,"e",1,VK_API_VERSION_1_1};
  VkInstanceCreateInfo ici={VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,0,0,&ai};
  VkInstance inst; CK(vkCreateInstance(&ici,0,&inst));
  uint32_t n=1; VkPhysicalDevice pd; VkResult r=vkEnumeratePhysicalDevices(inst,&n,&pd); if(r!=VK_SUCCESS&&r!=VK_INCOMPLETE){printf("enum %d\n",r);return 1;}
  VkPhysicalDeviceProperties pp; vkGetPhysicalDeviceProperties(pd,&pp);
  printf("GPU: %s api %u.%u.%u driver %x\n",pp.deviceName,VK_VERSION_MAJOR(pp.apiVersion),VK_VERSION_MINOR(pp.apiVersion),VK_VERSION_PATCH(pp.apiVersion),pp.driverVersion);
  uint32_t qn=8; VkQueueFamilyProperties qf[8]; vkGetPhysicalDeviceQueueFamilyProperties(pd,&qn,qf);
  uint32_t qi=0; for(;qi<qn;qi++) if(qf[qi].queueFlags&VK_QUEUE_GRAPHICS_BIT) break;
  float pr=1; VkDeviceQueueCreateInfo dq={VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,0,0,qi,1,&pr};
  VkDeviceCreateInfo dci={VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,0,0,1,&dq};
  VkDevice dev; CK(vkCreateDevice(pd,&dci,0,&dev)); VkQueue q; vkGetDeviceQueue(dev,qi,0,&q);
  VkImageCreateInfo ic={VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,0,0,VK_IMAGE_TYPE_2D,VK_FORMAT_R8G8B8A8_UNORM,{W,H,1},1,1,VK_SAMPLE_COUNT_1_BIT,VK_IMAGE_TILING_OPTIMAL,VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT};
  VkImage img; CK(vkCreateImage(dev,&ic,0,&img));
  VkMemoryRequirements mr; vkGetImageMemoryRequirements(dev,img,&mr);
  VkMemoryAllocateInfo ma={VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,0,mr.size,memtype(pd,mr.memoryTypeBits,VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)};
  VkDeviceMemory im; CK(vkAllocateMemory(dev,&ma,0,&im)); CK(vkBindImageMemory(dev,img,im,0));
  VkImageViewCreateInfo vc={VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,0,0,img,VK_IMAGE_VIEW_TYPE_2D,VK_FORMAT_R8G8B8A8_UNORM,{0,0,0,0},{VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}};
  VkImageView iv; CK(vkCreateImageView(dev,&vc,0,&iv));
  VkBufferCreateInfo bc={VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,0,0,W*H*4,VK_BUFFER_USAGE_TRANSFER_DST_BIT};
  VkBuffer buf; CK(vkCreateBuffer(dev,&bc,0,&buf)); vkGetBufferMemoryRequirements(dev,buf,&mr);
  ma.allocationSize=mr.size; ma.memoryTypeIndex=memtype(pd,mr.memoryTypeBits,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
  VkDeviceMemory bm; CK(vkAllocateMemory(dev,&ma,0,&bm)); CK(vkBindBufferMemory(dev,buf,bm,0));
  VkAttachmentDescription ad={0,VK_FORMAT_R8G8B8A8_UNORM,VK_SAMPLE_COUNT_1_BIT,VK_ATTACHMENT_LOAD_OP_CLEAR,VK_ATTACHMENT_STORE_OP_STORE,VK_ATTACHMENT_LOAD_OP_DONT_CARE,VK_ATTACHMENT_STORE_OP_DONT_CARE,VK_IMAGE_LAYOUT_UNDEFINED,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL};
  VkAttachmentReference ar={0,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
  VkSubpassDescription sd={0,VK_PIPELINE_BIND_POINT_GRAPHICS,0,0,1,&ar};
  VkRenderPassCreateInfo rc={VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,0,0,1,&ad,1,&sd};
  VkRenderPass rp; CK(vkCreateRenderPass(dev,&rc,0,&rp));
  VkFramebufferCreateInfo fc={VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,0,0,rp,1,&iv,W,H,1};
  VkFramebuffer fb; CK(vkCreateFramebuffer(dev,&fc,0,&fb));
  VkShaderModuleCreateInfo sc={VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,0,0,sizeof(vert_spv),vert_spv};
  VkShaderModule vs,fs; CK(vkCreateShaderModule(dev,&sc,0,&vs)); sc.codeSize=sizeof(frag_spv); sc.pCode=frag_spv; CK(vkCreateShaderModule(dev,&sc,0,&fs));
  VkPipelineLayoutCreateInfo lc={VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO}; VkPipelineLayout pl; CK(vkCreatePipelineLayout(dev,&lc,0,&pl));
  VkPipelineShaderStageCreateInfo st[2]={{VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,0,0,VK_SHADER_STAGE_VERTEX_BIT,vs,"main"},{VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,0,0,VK_SHADER_STAGE_FRAGMENT_BIT,fs,"main"}};
  VkPipelineVertexInputStateCreateInfo vi={VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
  VkPipelineInputAssemblyStateCreateInfo ia={VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,0,0,VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
  VkViewport vp={0,0,W,H,0,1}; VkRect2D sc2={{0,0},{W,H}};
  VkPipelineViewportStateCreateInfo vw={VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,0,0,1,&vp,1,&sc2};
  VkPipelineRasterizationStateCreateInfo rs={VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,0,0,0,0,VK_POLYGON_MODE_FILL,VK_CULL_MODE_NONE,VK_FRONT_FACE_CLOCKWISE,0,0,0,0,1.0f};
  VkPipelineMultisampleStateCreateInfo ms={VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,0,0,VK_SAMPLE_COUNT_1_BIT};
  VkPipelineColorBlendAttachmentState cba={0,0,0,0,0,0,0,0xF};
  VkPipelineColorBlendStateCreateInfo cb={VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,0,0,0,0,1,&cba};
  VkGraphicsPipelineCreateInfo gc={VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,0,0,2,st,&vi,&ia,0,&vw,&rs,&ms,0,&cb,0,pl,rp,0};
  VkPipeline pipe; CK(vkCreateGraphicsPipelines(dev,0,1,&gc,0,&pipe));
  VkCommandPoolCreateInfo pc={VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,0,0,qi}; VkCommandPool pool; CK(vkCreateCommandPool(dev,&pc,0,&pool));
  VkCommandBufferAllocateInfo cai={VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,0,pool,VK_COMMAND_BUFFER_LEVEL_PRIMARY,1}; VkCommandBuffer cmd; CK(vkAllocateCommandBuffers(dev,&cai,&cmd));
  VkCommandBufferBeginInfo bi={VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; CK(vkBeginCommandBuffer(cmd,&bi));
  VkClearValue cv; memset(&cv,0,sizeof cv); cv.color.float32[0]=0.05f; cv.color.float32[1]=0.05f; cv.color.float32[2]=0.1f; cv.color.float32[3]=1;
  VkRenderPassBeginInfo rb={VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,0,rp,fb,{{0,0},{W,H}},1,&cv};
  vkCmdBeginRenderPass(cmd,&rb,VK_SUBPASS_CONTENTS_INLINE); vkCmdBindPipeline(cmd,VK_PIPELINE_BIND_POINT_GRAPHICS,pipe); vkCmdDraw(cmd,3,1,0,0); vkCmdEndRenderPass(cmd);
  VkBufferImageCopy bcp={0,0,0,{VK_IMAGE_ASPECT_COLOR_BIT,0,0,1},{0,0,0},{W,H,1}};
  vkCmdCopyImageToBuffer(cmd,img,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,buf,1,&bcp); CK(vkEndCommandBuffer(cmd));
  VkSubmitInfo si={VK_STRUCTURE_TYPE_SUBMIT_INFO,0,0,0,0,1,&cmd}; CK(vkQueueSubmit(q,1,&si,0)); CK(vkQueueWaitIdle(q));
  uint8_t*p; CK(vkMapMemory(dev,bm,0,W*H*4,0,(void**)&p));
  FILE*f=fopen("/data/local/tmp/tri.ppm","wb"); fprintf(f,"P6\n%d %d\n255\n",W,H);
  for(int i=0;i<W*H;i++) fwrite(p+i*4,1,3,f); fclose(f);
  int c=(H/2*W+W/2)*4;
  printf("OK center=%02x%02x%02x corner=%02x%02x%02x\n",p[c],p[c+1],p[c+2],p[0],p[1],p[2]);
  return 0;
}
