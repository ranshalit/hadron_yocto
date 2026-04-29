Hadron (NGX012/NGX024/NGX027) Flashing Troubleshooting
7 months ago Updated
Hadron/Hadron DM Carrier Manual: https://connecttech.com/ftp/pdf/CTIM-00088.pdf

 

The Hadron carrier board is compatible with the following modules:

NVIDIA® Jetson Xavier™ NX
NVIDIA® Jetson Orin™ NX
NVIDIA® Jetson Orin™ Nano
 

This article provides diagnostic steps to the most common issues found related to difficulties flashing the Hadron system.

 

1. Confirm OS of host machine

       Flashing the system should be done from a native installation of Ubuntu 18.04/20.04 for JetPack 5 or Ubuntu 20.04/22.04 for JetPack 6.

2. Ensure the correct port and cable is being used to flash

       The Hadron includes 2x USB 3.1, however, only one (Port 0) has OTG capability. Please verify this is the port being used for flashing. A pinout of the USB 3.1 connector can be found on page 16 of the manual.

        Additionally, try testing out different cables/ports on the host computer to rule out any external hardware issues.

3. Verify the power supply

       The input voltage range for the Hadron is +9V to +60V (+10V to +60V for NGX027). Further, ensure your current limit is set to at least 3A as the module may draw upwards of 2.5-3A on boot.

4. Ensure the Hadron system is in recovery mode

       Instructions on how to put the Hadron into forced recovery mode can be found on page 23 of the manual. To confirm it has been successfully put into force recovery mode run watch lsusb from a terminal prior to following the Force Recovery instructions and confirm a NVIDIA Corp. device enumerates during the process.

5. Confirm the USB dip switch is set to device mode 

       The USB dip switch (SW1) can be set to Host or Device mode. Ensure the board is set to Device mode as shown on page 24 of the manual.

6. Try using CTI's alternate flashing method

       An alternate method to flash is through CLI, this procedure is as follows:

$ sudo su
$ mkdir <L4T Directory> && cd <L4T Dir>
$ wget https://developer.nvidia.com/downloads/embedded/l4t/<RELEASE VERSION>/release/<DRIVER PACKAGE (BSP)>
$ wget https://developer.nvidia.com/downloads/embedded/l4t/<RELEASE VERSION>/release/<SAMPLE ROOT FILESYSTEM>
$ wget https://connecttech.com/ftp/Drivers/<CTI L4T BSP>
$ tar -xvf <DRIVER PACKAGE (BSP)>
$ tar -xvf <SAMPLE ROOT FILESYSTEM> -C Linux_for_Tegra/rootfs
$ tar -xvf <CTI L4T BSP> -C Linux_for_Tegra
$ cd Linux_for_Tegra/CTI-L4T
$ ./install.sh 2>&1 | tee install.txt
$ cd ..
$ ./cti-flash.sh 2>&1 | tee flash.txt
       Note, the wget & tar lines will need to be changed based on what L4T version is being built. 

       NVIDIA downloads can be found here: https://developer.nvidia.com/embedded/downloads & CTI downloads here: https://connecttech.com/resource-center/l4t-board-support-packages/ 

 

If you are still having trouble flashing your Hadron device after going through each step, please reach out to CTI support and provide the install.txt and flash.txt files generated in diagnostic step 6.
