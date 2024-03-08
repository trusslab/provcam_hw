# ProvCam: A Camera Module with Self-Contained TCB for Producing Verifiable Videos

:paperclip: [ProvCam Paper](https://doi.org/10.1145/3636534.3649383) 

:computer: [ProvCam Main Repository](https://github.com/trusslab/provcam)
This repo hosts the documentation of ProvCam and other misc content. 

:computer: [ProvCam Hardware Repository](https://github.com/trusslab/provcam_hw)
This repo hosts ProvCam's hardware system design.

:computer: [ProvCam Firmware Repository](https://github.com/trusslab/provcam_ctrl)
This repo hosts firmware running the microcontroller of ProvCam trusted camera module.

:computer: [ProvCam OS Repository](https://github.com/trusslab/provcam_linux)
This repo hosts OS(a custom version of Petalinux) running on ProvCam's system. 
Notice that the OS represents the main camera OS, which is untrusted in ProvCam. 

:computer: [ProvCam Software Repository](https://github.com/trusslab/provcam_libs/tree/main)
This repo hosts some software and libraries running in the OS.

Authors: \
[Yuxin (Myles) Liu](https://lab.donkeyandperi.net/~yuxinliu/) (UC Irvine)\
[Zhihao Yao](https://web.njit.edu/~zy8/) (NJIT)\
[Mingyi Chen](https://imcmy.me/) (UC Irvine)\
[Ardalan Amiri Sani](https://ics.uci.edu/~ardalan/) (UC Irvine)\
[Sharad Agarwal](https://sharadagarwal.net/) (Microsoft)\
[Gene Tsudik](https://ics.uci.edu/~gts/) (UC Irvine)

The work of UCI authors was supported in part by the NSF Awards #1763172, #1953932, #1956393, and #2247880 as well as NSA Awards #H98230-20-1-0345 and #H98230-22-1-0308.

We provide design/implmentation documentation and a step-by-step guide to recreate ProvCam's hardware and software prototype mentioned in our paper. 

---

## Table of Contents

- [ProvCam](https://github.com/trusslab/provcam/tree/main?tab=readme-ov-file#provcam-a-camera-module-with-self-contained-tcb-for-producing-verifiable-videos)
    - [Table of Contents](https://github.com/trusslab/provcam/tree/main?tab=readme-ov-file#table-of-contents)
    - [Hardware](https://github.com/trusslab/provcam_hw/tree/main/sources?tab=readme-ov-file#hardware)
        - [GENERAL_HASHER (sha256_core.v)](https://github.com/trusslab/provcam_hw/tree/main/sources?tab=readme-ov-file#general_hasher-sha256_corev)
        - [ISP_HASHER (r_hasher_4_isp.v)](https://github.com/trusslab/provcam_hw/tree/main/sources?tab=readme-ov-file#isp_hasher-r_hasher_4_ispv)
        - [ENCODER_HASHER (axixbar.v)](https://github.com/trusslab/provcam_hw/tree/main/sources?tab=readme-ov-file#encoder_hasher-axixbarv)
    - [Firmware](https://github.com/trusslab/provcam_ctrl/tree/main?tab=readme-ov-file#firmware)
    - [OS](https://github.com/trusslab/provcam_linux/tree/main?tab=readme-ov-file#os)
    - [Libraries](https://github.com/trusslab/provcam_libs/tree/main?tab=readme-ov-file#libraries)
    - [Build](https://github.com/trusslab/provcam/tree/main?tab=readme-ov-file#build)
        - [System Requirements](https://github.com/trusslab/provcam/tree/main?tab=readme-ov-file#system-requirements)
            - [Hardware](https://github.com/trusslab/provcam/tree/main?tab=readme-ov-file#hardware)
            - [Xilinx Vivado and Vitis](https://github.com/trusslab/provcam/tree/main?tab=readme-ov-file#xilinx-vivado-and-vitis)
            - [Xilinx Petalinux](https://github.com/trusslab/provcam/tree/main?tab=readme-ov-file#xilinx-petalinux)
            - [Misc.](https://github.com/trusslab/provcam/tree/main?tab=readme-ov-file#misc)
        - [Hadware Design](https://github.com/trusslab/provcam/tree/main?tab=readme-ov-file#hadware-design)
        - [Firmware](https://github.com/trusslab/provcam/tree/main?tab=readme-ov-file#firmware)
        - [OS](https://github.com/trusslab/provcam/tree/main?tab=readme-ov-file#os)
    - [Run](https://github.com/trusslab/provcam/tree/main?tab=readme-ov-file#run)
        - [Preparing the SD Card](https://github.com/trusslab/provcam/tree/main?tab=readme-ov-file#preparing-the-sd-card)
        - [Hardware Preparation](https://github.com/trusslab/provcam/tree/main?tab=readme-ov-file#hardware-preparation)
        - [Preparing the UART Consoles](https://github.com/trusslab/provcam/tree/main?tab=readme-ov-file#preparing-the-uart-consoles)
        - [Preparing the Vitis Debug Environment](https://github.com/trusslab/provcam/tree/main?tab=readme-ov-file#preparing-the-vitis-debug-environment)
        - [Running ProvCam](https://github.com/trusslab/provcam/tree/main?tab=readme-ov-file#running-provcam)
    - [References](https://github.com/trusslab/provcam/tree/main?tab=readme-ov-file#references)

## Hardware

### GENERAL_HASHER (sha256_core.v)
This module is a simple SHA-256 core that can be used to hash the video frames. It is used in the ISP_HASHER and ENCODER_HASHER modules.
This module is built on top of an open source SHA-256 IP from secworks. The original source code and its documentation can be found [here](https://github.com/secworks/sha256)

Our modification involves some minor bug fixes and performance enhancement. 
We have removed some unnecessary features to make the core more lightweight.
We have also made other minor changes to make the core more compatible with our design.

### ISP_HASHER (r_hasher_4_isp.v)
This IP is used to hash the video frames after they are processed by the ISP and before they are stored in the DDR memory, which is untrusted. 
It is used to ensure the integrity of the video frames before they are encoded.
This IP is built on top of an open source AXI CrossBar IP from ZipCPU. The original source code and its documentation can be found [here](https://github.com/ZipCPU/wb2axip/tree/master/rtl)

The IP takes YUV 4:2:0 video frames as input and hashes them using the GENERAL_HASHER module. 
Two ring buffers are used to temporiarily store the video frames, and two hashers are used to hash Y and UV data separately. 
This allows us to minimize the latency introduced by our IP to the video pipeline. 
Whenever we have enough data for either Y or UV data for a single hash block (512-bit), we feed it to its corresponding hasher. 
When the hashing is done, the hash values are stored in another two ring buffers: one for Y, and one for UV. 
The top Y and UV hash values are then exposed at the output of the IP, which is connected to the ENCODER_HASHER IP. 
The IP expects the ENCODER_HASHER IP to verify the hash values and send back the verification signal. 
Once receving the verification signal, the IP reads the next Y and UV hashes from the ring buffers and continue the process.

If anything goes wrong during the entire process, the IP raises an error flag, which is picked up by the camera's microcontroller.

### ENCODER_HASHER (axixbar.v)
This IP has two purposes:
1. It hashes the raw YUV 4:2:0 video frames read from the DDR memory, which is untrusted, and compare the hash values with the ones generated by the ISP_HASHER IP.\
2. It hashes the encoded video frames.\
This IP is built on top of an open source AXI CrossBar IP from ZipCPU. The original source code and its documentation can be found [here](https://github.com/ZipCPU/wb2axip/tree/master/rtl)

Due to different write and read patterns of the raw YUV frame used by the ISP and video encoder, we have to make use of what we called as reorder buffer. Otherwise the hash values generated by the ENCODER_HASHER IP will not match the ones generated by the ISP_HASHER IP. 
To achieve the purpose of reordering, we have closely studied how the frame access patterns by both the ISP and encoder. 
First, Y and UV data in a raw YUV frame are transferred separately in multiple AXI burst transactions, which means we have to reorder them independently. 
Second, by knowing the exact resolution configuration, we can calculate logical addresses for putting all pixels' Y and UV data into their correct locations in the reorder buffer. 
More specifically, we have created two address translation tools. 
The first one translates the current transaction's physical address to a relative address, 
and the second one translates the relative address to our buffer's logical address. 
Finally, for size of the reorder buffer, we have to match its width with the width of a full-resolution frame, 
and its height has to be the same as the width of the encoding block. 
However, this is still not enough. 
Hashing is not instant, and due to the nature of bursting transactions, new data could come in at a faster speed compared with how existing data is being hashed, 
where non-hashed data may be overwritten by the new data. 
To overcome this, we have doubled the size of the reorder buffer, leaving only one-half of it being read by the hasher, 
and another half of it is written with the new data.

We now provide a concrete example of how an AXI transaction address is used to determine where to put the upcoming data in the reorder buffer. 
Assuming we are dealing with 720p resolution with a physical start address of 0xC400000, and the encoder works on macroblocks of 16x16, 
if we encounter the address 0xC4E3D00, we know that the following transaction is a UV data transaction for the start of the 18th row of a frame, 
which can then be translated to a raw frame's relative address 0xE3D00. 
As we know this is a UV data transaction, we can further get the data-specific relative address, which is 0x2D00. 
Furthermore, we compute the logical address of the transaction with the encoder macroblock's configuration, where we can get 0xA00.
After getting the transaction's reorder buffer logical address, we still need to calculate its physical address in the reorder buffer. 
As this is for the 18th row of a frame, we know that we are using the second half of the reorder buffer, 
which has a physical start address of 0x7800; 
also, since we are dealing with UV data, the physical start address should be updated to 0xC800. 
Finally, by combining with the logical address we get above, 
we can now calculate the final physical address of the reorder buffer for this transaction, which is 0xD200. 

Once the reordering is done, we proceed using the GENERAL_HASHER module to hash the data. 
Once hashing is done, we check if the hash value matches the one generated by the ISP_HASHER IP.
If not, instead of raising an error flag, we simply ask the ISP_HASHER IP to provide the next hash values. 
The reason we do this is that frames could be dropped during the video pipeline, and we do not want to raise an error flag for every dropped frame. 
This will at most cause a denial of service attack, but will not compromise the integrity of the video frames. 
The hashes of the old frame remains there until there is a match with the ISP_HASHER IP. 

For the second purpose, we hash the encoded video frames. 
As discussed in the paper, we hash the frame one by one instead of hashing the entire video file. 
Please refer to the paper for more details.
