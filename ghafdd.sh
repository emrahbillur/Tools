#!/bin/bash
#Check if run by root user or sudo
if [ "$EUID" -ne 0 ]
  then echo "Please run as root. Needed for flashing usb."
  exit
fi

#Check if the result/sd-image directory exists
echo "Checking if the image file exists"
if [ -d "./result/sd-image" ] && [ -n "$(ls -A "./result/sd-image")" ]; then
   FILE=$(ls result/sd-image/*.zst)
   echo "The image is " $FILE
else 
   echo "Image file not found!!!"
   echo "Please run nix build to create the disk image and ensure you are in the build directory"   
   exit 1
fi
echo "Detected the image file: " $FILE
echo "Checking the required minimum size for USB drive"
zstdcat "./"$FILE |pv -b >/dev/null

echo "\n Please insert a usb drive to flash ghaf image and Press any key to continue..."
 
# -s: Do not echo input coming from a terminal
# -n 1: Read one character
read -s -n 1
 
echo "You pressed a key! Continuing..."
sleep 2
DRIVE=$(dmesg |grep -o sd[a-z]: |tail -n1)
DRIVE=${DRIVE::-1}
DRIVE="/dev/"$DRIVE
DEVICE1=$DRIVE"1"
DEVICE2=$DRIVE"2"
if [ -b $DRIVE ]
then
   echo "The USB drive is "$DRIVE
else
   echo "The USB drive is "$DRIVE
   echo "USB not detected"
   echo "Please ensure your system is able to find usb device and re-run this script"
   exit 2
fi

echo "Checking if the usb partitions are mounted - Will unmount if mounted to ensure image is not corrupted"
while findmnt $DEVICE1 >/dev/null; do
	umount $DEVICE1 >/dev/null
done
echo "Device "$DEVICE1 "is safe"

while findmnt $DEVICE2 >/dev/null; do
	umount $DEVICE2 >/dev/null
done
echo "Device "$DEVICE2 "is safe"

echo "Writing the image on USB"
zstdcat -v $FILE > $DRIVE 

echo "Successfully written image to USB"
exit 0

