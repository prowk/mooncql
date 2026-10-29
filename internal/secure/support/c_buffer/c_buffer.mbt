// 修改声明：prowk/mooncql 基于 moonbitlang/async 0.22.3 修改。
// 隔离辅助包与 FFI 符号，适配驱动自有内存及系统字符串接口。来源及上游原始哈希见 internal/secure/NOTICE.md 和 UPSTREAM.json。

// Copyright 2025 International Digital Economy Academy
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
#external
pub type Buffer

///|
#borrow(src)
pub extern "C" fn Buffer::blit_from_bytes(
  dst : Buffer,
  dst_offset~ : Int32 = 0,
  src~ : Bytes,
  src_offset~ : Int32 = 0,
  len~ : Int32,
) = "prowk_mooncql_secure_blit_to_c"

///|
#borrow(dst)
pub extern "C" fn Buffer::blit_to_bytes(
  src : Buffer,
  src_offset~ : Int32 = 0,
  dst~ : FixedArray[Byte],
  dst_offset~ : Int32 = 0,
  len~ : Int32,
) = "prowk_mooncql_secure_blit_from_c"

///|
#borrow(buf)
#alias("_[_]")
pub extern "C" fn Buffer::get(buf : Buffer, index : Int32) -> Byte = "prowk_mooncql_secure_c_buffer_get"

///|
pub extern "C" fn Buffer::strlen(buf : Buffer, offset~ : Int32 = 0) -> Int32 = "prowk_mooncql_secure_strlen"

///|
pub extern "C" fn Buffer::is_null(ptr : Buffer) -> Bool = "prowk_mooncql_secure_pointer_is_null"

///|
pub extern "C" fn Buffer::free(buf : Buffer) = "free"

///|
#as_free_fn
pub extern "C" fn Buffer::new(size : Int32) -> Buffer = "prowk_mooncql_secure_make_c_buffer"
