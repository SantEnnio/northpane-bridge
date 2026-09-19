#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
checkout="$repository_root/.build/checkouts/swift-protobuf"
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

swift package --package-path "$repository_root" resolve
swift build --package-path "$checkout" -c release --product protoc-gen-swift >/dev/null
plugin_directory=$(swift build --package-path "$checkout" -c release --show-bin-path)

protoc --proto_path "$repository_root/Protocol" \
  --plugin="protoc-gen-swift=$plugin_directory/protoc-gen-swift" \
  --swift_opt=FileNaming=DropPath \
  --swift_opt=Visibility=Internal \
  --swift_out="$temporary_directory" \
  "$repository_root/Protocol/bridge-v1.proto"

diff -u "$repository_root/Sources/NorthpaneProtocol/bridge-v1.pb.swift" "$temporary_directory/bridge-v1.pb.swift"
revision_one_hash=$(shasum -a 256 "$repository_root/Protocol/compatibility/bridge-v1-revision-1.proto" | awk '{print $1}')
[ "$revision_one_hash" = "14bb043944d3d5a6d02db3952f6f6516d5682b712f336fd1605d7d0653eee417" ]
revision_two_hash=$(shasum -a 256 "$repository_root/Protocol/compatibility/bridge-v1-revision-2.proto" | awk '{print $1}')
[ "$revision_two_hash" = "57f494f2b60d4370f87792e7cd071f6d09860657298b8c6c2aba33f85576673f" ]
revision_three_hash=$(shasum -a 256 "$repository_root/Protocol/compatibility/bridge-v1-revision-3.proto" | awk '{print $1}')
[ "$revision_three_hash" = "b2707bb62b5881121e52d0d442f7b4e18320e07f38c78a3ba85cbf1b818c2662" ]
revision_four_hash=$(shasum -a 256 "$repository_root/Protocol/compatibility/bridge-v1-revision-4.proto" | awk '{print $1}')
[ "$revision_four_hash" = "b09af06eae57f0a26f21f8e68ec17faefe1753f3b0b3efe4b98e059c1a2d2f79" ]
revision_five_hash=$(shasum -a 256 "$repository_root/Protocol/compatibility/bridge-v1-revision-5.proto" | awk '{print $1}')
[ "$revision_five_hash" = "a1cd27b5544d3e4e4dc3d6a3d53807853b210f9cd0a0d2ee4a03ba89fc934388" ]
revision_six_hash=$(shasum -a 256 "$repository_root/Protocol/compatibility/bridge-v1-revision-6.proto" | awk '{print $1}')
[ "$revision_six_hash" = "a1cd27b5544d3e4e4dc3d6a3d53807853b210f9cd0a0d2ee4a03ba89fc934388" ]
revision_seven_hash=$(shasum -a 256 "$repository_root/Protocol/compatibility/bridge-v1-revision-7.proto" | awk '{print $1}')
[ "$revision_seven_hash" = "8401817ef87747e97fd56059564575b62de23797f1925914ffa5c559022eb1d1" ]
revision_eight_hash=$(shasum -a 256 "$repository_root/Protocol/compatibility/bridge-v1-revision-8.proto" | awk '{print $1}')
[ "$revision_eight_hash" = "1d9f3a7e4165b9c0ca20316dc1e369e82dcc50a11d0a56b16b3b99689e77dc58" ]
revision_nine_hash=$(shasum -a 256 "$repository_root/Protocol/compatibility/bridge-v1-revision-9.proto" | awk '{print $1}')
[ "$revision_nine_hash" = "85b81846c56b230e56507ed64c8450ffd0df5013f17865b522620af63363e884" ]
revision_ten_hash=$(shasum -a 256 "$repository_root/Protocol/compatibility/bridge-v1-revision-10.proto" | awk '{print $1}')
[ "$revision_ten_hash" = "658d66ac06712585181111956cb37f84d6c46b41af586a9abff1ab86c4b967a6" ]
revision_eleven_hash=$(shasum -a 256 "$repository_root/Protocol/compatibility/bridge-v1-revision-11.proto" | awk '{print $1}')
[ "$revision_eleven_hash" = "d5b6d7e68251c44eada0932b96bc0c79c31b3e255084407c58938a5d468cb44c" ]
revision_twelve_hash=$(shasum -a 256 "$repository_root/Protocol/compatibility/bridge-v1-revision-12.proto" | awk '{print $1}')
[ "$revision_twelve_hash" = "f6a55df0d674acc0f1252d9878ceac5d31f6bf2381a90d575b7232c6d29a20d4" ]
revision_thirteen_hash=$(shasum -a 256 "$repository_root/Protocol/compatibility/bridge-v1-revision-13.proto" | awk '{print $1}')
[ "$revision_thirteen_hash" = "f6a55df0d674acc0f1252d9878ceac5d31f6bf2381a90d575b7232c6d29a20d4" ]
revision_fourteen_hash=$(shasum -a 256 "$repository_root/Protocol/compatibility/bridge-v1-revision-14.proto" | awk '{print $1}')
[ "$revision_fourteen_hash" = "e5cf771920eb7d3707bcd71140151493c724be024994e54b317d938bbe2d6745" ]
revision_fifteen_hash=$(shasum -a 256 "$repository_root/Protocol/compatibility/bridge-v1-revision-15.proto" | awk '{print $1}')
[ "$revision_fifteen_hash" = "e5cf771920eb7d3707bcd71140151493c724be024994e54b317d938bbe2d6745" ]
revision_sixteen_hash=$(shasum -a 256 "$repository_root/Protocol/compatibility/bridge-v1-revision-16.proto" | awk '{print $1}')
[ "$revision_sixteen_hash" = "4371681fa2e6bbbee144eb5fe6aea3c4547b117248ae6085d6d260616ab1fc0c" ]
diff -u "$repository_root/Protocol/compatibility/bridge-v1-revision-17.proto" "$repository_root/Protocol/bridge-v1.proto"

echo "Generated Protobuf source matches revision 17; frozen revisions 1 to 16 are unchanged"
