let seed = "kle6/0eMVRsY+AlbHjLTMQ=="

let () =
  let raw = Base64.decode_exn seed in
  let res = Array.make 8 0 in
  for i = 0 to 7 do res.(i) <- (Char.code raw.[i] lsl 8) lor (Char.code raw.[i + 1]) done ;
  Random.full_init res

let random len =
  let res = Bytes.create len in
  for i = 0 to len - 1 do Bytes.set res i (Char.chr (Random.int 256)) done ;
  Bytes.unsafe_to_string res

open De (* au detail *)

let w = make_window ~bits:15
let i = bigstring_create io_buffer_size
let o = bigstring_create io_buffer_size
let q = Queue.create 4096

let unsafe_get_uint8 b i = Char.code (Bigstringaf.get b i)
let unsafe_get_uint32_be b i = Bigstringaf.get_int32_be b i

let pp_chr =
  Fmt.using (function '\032' .. '\126' as x -> x | _ -> '.') Fmt.char

let pp_scalar : type buffer.
    get:(buffer -> int -> char) -> length:(buffer -> int) -> buffer Fmt.t =
 fun ~get ~length ppf b ->
  let l = length b in
  for i = 0 to l / 16 do
    Fmt.pf ppf "%08x: " (i * 16) ;
    let j = ref 0 in
    while !j < 16 do
      if (i * 16) + !j < l then
        Fmt.pf ppf "%02x" (Char.code @@ get b ((i * 16) + !j))
      else Fmt.pf ppf "  " ;
      if !j mod 2 <> 0 then Fmt.pf ppf " " ;
      incr j
    done ;
    Fmt.pf ppf "  " ;
    j := 0 ;
    while !j < 16 do
      if (i * 16) + !j < l then Fmt.pf ppf "%a" pp_chr (get b ((i * 16) + !j))
      else Fmt.pf ppf " " ;
      incr j
    done ;
    Fmt.pf ppf "@\n"
  done

let pp_string = pp_scalar ~get:String.get ~length:String.length

let str = Alcotest.testable pp_string String.equal

let decode =
  let pp ppf = function
    | `Await -> Fmt.string ppf "`Await"
    | `Flush -> Fmt.string ppf "`Flush"
    | `End -> Fmt.string ppf "`End"
    | `Malformed err -> Fmt.pf ppf "(`Malformed %s)" err in
  let equal a b = match a, b with
    | `Await, `Await -> true
    | `Flush, `Flush -> true
    | `End, `End -> true
    | `Malformed a, `Malformed b -> String.equal a b
    | _, _ -> false in
  Alcotest.testable pp equal

let encode ~block:kind lst =
  let res = Buffer.create 16 in
  let q = Queue.of_list lst in
  let encoder = Def.encoder (`Buffer res) ~q in
  match Def.encode encoder (`Block { kind; last= true; }) with
  | `Block -> assert false
  | `Partial -> assert false
  | `Ok -> match Def.encode encoder `Flush with
    | `Ok -> Buffer.contents res
    | `Block -> Alcotest.fail "Bad block"
    | `Partial -> assert false

let encode_dynamic lst =
  let literals = make_literals () in
  let distances = make_distances () in
  List.iter
    (function
     | `Literal chr -> succ_literal literals chr
     | `Copy (off, len) ->
        succ_length literals len ;
        succ_distance distances off
     | _ -> ())
    lst ;
  let dynamic = Def.dynamic_of_frequencies ~literals ~distances in
  encode ~block:(Def.Dynamic dynamic) lst

let invalid_complement_of_length () =
  Alcotest.test_case "invalid complement of length" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\x00\x00\x00\x00\x00") ~o ~w in
  Alcotest.(check decode) "invalid complement of length"
    (Inf.decode decoder) (`Malformed "Invalid complement of length")

let invalid_kind_of_block () =
  Alcotest.test_case "invalid kind of block" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\x06") ~o ~w in
  Alcotest.(check decode) "invalid kind of block"
    (Inf.decode decoder) (`Malformed "Invalid kind of block")

let invalid_code_lengths () =
  Alcotest.test_case "invalid code lengths" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\x04\x00\xfe\xff") ~o ~w in
  Alcotest.(check decode) "invalid code lengths"
    (Inf.decode decoder) (`Malformed "Invalid dictionary")

let invalid_bit_length_repeat () =
  Alcotest.test_case "invalid bit length repeat" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\x04\x00\x24\x49\x00") ~o ~w in
  Alcotest.(check decode) "invalid bit length repeat"
    (Inf.decode decoder) (`Malformed "Invalid dictionary")

let invalid_codes () =
  Alcotest.test_case "invalid codes -- missing end-of-block" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\x04\x00\x24\xe9\xff\x6d") ~o ~w in
  Alcotest.(check decode) "invalid codes -- missing end-of-block"
    (Inf.decode decoder) (`Malformed "Invalid dictionary")

let invalid_lengths () =
  Alcotest.test_case "invalid literals/lengths" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\x04\x80\x49\x92\x24\x49\x92\x24\x49\x92\x24\x71\xff\xff\x93\x11\x00") ~o ~w in
  Alcotest.(check decode) "invalid literals/lengths"
    (Inf.decode decoder) (`Malformed "Invalid dictionary")

let invalid_distances () =
  Alcotest.test_case "invalid distances" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\x04\x80\x49\x92\x24\x49\x92\x24\x0f\xb4\xff\xff\xc3\x84") ~o ~w in
  Alcotest.(check decode) "invalid distances"
    (Inf.decode decoder) (`Malformed "Invalid dictionary")

let too_many_length_or_distance_symbols () =
  Alcotest.test_case "too many length of distance symbols" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\xfc\x00\x00") ~o ~w in
  Alcotest.(check decode) "too many length of distance symbols"
    (Inf.decode decoder) (`Malformed "Unexpected end of input")
(* XXX(dinosaure): error is not conform to what we expect (best will be [Invalid
   dictionary]), TODO! *)

let invalid_distance_code () =
  Alcotest.test_case "invalid distance code" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\x02\x7e\xff\xff") ~o ~w in
  Alcotest.(check decode) "invalid distance code"
    (Inf.decode decoder) (`Malformed "Invalid distance code") ;
  Alcotest.(check string) "non-corrupted output"
    "" (Bigstringaf.substring o ~off:0 ~len:(Bigstringaf.length o - Inf.dst_rem decoder))
(* XXX(dinosaure): see [Inf.base_dist]'s comment about this behavior. *)

let invalid_distance_too_far_back () =
  Alcotest.test_case "invalid distance too far back" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\x0c\xc0\x81\x00\x00\x00\x00\x00\x90\xff\x6b\x04\x00") ~o ~w in
  Alcotest.(check decode) "invalid distance too far back"
    (Inf.decode decoder) (`Malformed "Invalid distance")

let fixed () =
  Alcotest.test_case "fixed" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\x03\x00") ~o ~w in
  Alcotest.(check decode) "fixed"
    (ignore @@ Inf.decode decoder ; Inf.decode decoder) `End ;
  Alcotest.(check string) "empty"
    "" (Bigstringaf.substring o ~off:0 ~len:(Bigstringaf.length o - Inf.dst_rem decoder))

let stored () =
  Alcotest.test_case "stored" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\x01\x01\x00\xfe\xff\x00") ~o ~w in
  Alcotest.(check decode) "stored"
    (ignore @@ Inf.decode decoder ; Inf.decode decoder) `End ;
  Alcotest.(check string) "0x00"
    "\x00" (Bigstringaf.substring o ~off:0 ~len:(Bigstringaf.length o - Inf.dst_rem decoder))

let unroll_inflate decoder =
  let buf = Buffer.create 16 in
  let rec go () = match Inf.decode decoder with
    | `Flush ->
       for i = 0 to io_buffer_size - Inf.dst_rem decoder - 1
       do Buffer.add_char buf (Char.unsafe_chr (unsafe_get_uint8 o i)) done ;
       Inf.flush decoder ; go ()
    | `Await -> Alcotest.fail "Impossible `Await case"
    | `Malformed err -> Alcotest.fail err
    | `End ->
      for i = 0 to io_buffer_size - Inf.dst_rem decoder - 1
      do Buffer.add_char buf (Char.unsafe_chr (unsafe_get_uint8 o i)) done ;
      Buffer.contents buf in
  go ()

let length_extra () =
  Alcotest.test_case "length extra" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\xed\xc0\x01\x01\x00\x00\x00\x40\x20\xff\x57\x1b\x42\x2c\x4f") ~o ~w in
  let res = unroll_inflate decoder in
  Fmt.epr "Buffer length: %d.\n%!" (String.length res) ;
  Alcotest.(check string) "0x00 * 516"
    (String.make 516 '\x00') res

let long_distance_and_extra () =
  Alcotest.test_case "long distance and extra" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\xed\xcf\xc1\xb1\x2c\x47\x10\xc4\x30\xfa\x6f\x35\x1d\x01\x82\x59\x3d\xfb\
                                      \xbe\x2e\x2a\xfc\x0f\x0c") ~o ~w in
  let res = unroll_inflate decoder in
  Alcotest.(check string) "0x00 * 518"
    (String.make 518 '\x00') res

let window_end () =
  Alcotest.test_case "window end" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\xed\xc0\x81\x00\x00\x00\x00\x80\xa0\xfd\xa9\x17\xa9\x00\x00\x00\x00\x00\
                                      \x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\
                                      \x00\x00\x00\x00\x00\x00\x00\x00\x00\x06") ~o ~w in
  let res = unroll_inflate decoder in
  Alcotest.(check string) "0x00 * 33025"
    (String.make 33025 '\x00') res

let flat_of_string () =
  Alcotest.test_case "flat of string" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\x01\x00\x00\xff\xff") ~o ~w in
  let res = unroll_inflate decoder in
  Alcotest.(check string) "empty" "" res

let flat_block () =
  Alcotest.test_case "flat block" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\x01\x04\x00\xfb\xff\xde\xad\xbe\xef") ~o ~w in
  let res = unroll_inflate decoder in
  Alcotest.(check string) "deadbeef" "\xde\xad\xbe\xef" res

let fuzz0 () =
  Alcotest.test_case "fuzz0" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "{\220\n s\017\027\211\\\006\211w\176`\142\2007\156oZBo\163\136\017\247\
                                      \158\247\012e\241\234sn_$\210\223\017\213\138\147]\129M\137<\242\1867\021\
                                      c\194\156\135\194\167-wo\006\200\198") ~o ~w in
  Alcotest.(check decode) "fuzz0"
    (ignore @@ Inf.decode decoder ; Inf.decode decoder) `End ;
  Alcotest.(check string) "fuzz0"
    "\xe3\x85" (Bigstringaf.substring o ~off:0 ~len:(Bigstringaf.length o - Inf.dst_rem decoder))

let fuzz1 () =
  Alcotest.test_case "fuzz1" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\019\208nO\200\189r\020\176") ~o ~w in
  Alcotest.(check decode) "fuzz1"
    (ignore @@ Inf.decode decoder ; Inf.decode decoder) `End ;
  Alcotest.(check string) "fuzz1"
    "\016+\135`m\212\197" (Bigstringaf.substring o ~off:0 ~len:(Bigstringaf.length o - Inf.dst_rem decoder))

let fuzz2 () =
  let expected_output =
    [ "\x1a\xca\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e" (* ..~~~~~~~~~~~~~~ *)
    ; "\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e" (* ~~~~~~~~~~~~~~~~ *)
    ; "\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e" (* ~~~~~~~~~~~~~~~~ *)
    ; "\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x7e\x3a\x2c\x50"                     (* ~~~~~~~~:,P *)      ] in
  Alcotest.test_case "fuzz2" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\x93\x3a\x55\x47\x12\x80\x51\x56\x3a\x01\x00\x00") ~o ~w in
  let res = unroll_inflate decoder in
  Alcotest.(check string) "fuzz2"
    (String.concat "" expected_output) res

let fuzz3 () =
  let expected_output =
    [ "\x1a\xca\x7e\x1a\xca\x7e\x1a\xca\x7e\x1a\xca\x7e\x1a\xca\x7e\x1a" (* ..~..~..~..~..~. *)
    ; "\xca\x7e\x1a\xca\x7e\x1a\xca\x7e\x1a\xca\x7e\x1a\xca\x7e\x1a\xca" (* .~..~..~..~..~.. *)
    ; "\x7e\x1a\xca\x7e\x1a\xca\x7e\x1a\xca\x7e\x1a\xca\x7e\x1a\xca\x7e" (* ~..~..~..~..~..~ *)
    ; "\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76" (* .v.v.v.v.v.v.v.v *)
    ; "\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76" (* .v.v.v.v.v.v.v.v *)
    ; "\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76" (* .v.v.v.v.v.v.v.v *)
    ; "\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76" (* .v.v.v.v.v.v.v.v *)
    ; "\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76" (* .v.v.v.v.v.v.v.v *)
    ; "\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76" (* .v.v.v.v.v.v.v.v *)
    ; "\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76" (* .v.v.v.v.v.v.v.v *)
    ; "\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76" (* .v.v.v.v.v.v.v.v *)
    ; "\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76" (* .v.v.v.v.v.v.v.v *)
    ; "\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76" (* .v.v.v.v.v.v.v.v *)
    ; "\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76" (* .v.v.v.v.v.v.v.v *)
    ; "\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76" (* .v.v.v.v.v.v.v.v *)
    ; "\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76" (* .v.v.v.v.v.v.v.v *)
    ; "\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76" (* .v.v.v.v.v.v.v.v *)
    ; "\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76" (* .v.v.v.v.v.v.v.v *)
    ; "\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76\xc8\x76" (* .v.v.v.v.v.v.v.v *)
    ; "\xc8\x76\xc8\x76"                                                 (* .v.v *)             ] in
  Alcotest.test_case "fuzz3" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\x93\x3a\x55\x47\x12\x3a\x51\x36\x0a\x01\x00\x00") ~o ~w in
  let res = unroll_inflate decoder in
  Alcotest.(check string) "fuzz3"
    (String.concat "" expected_output) res

let fuzz4 () =
  let expected_output =
    [ "\x1a\xca\x7e\x1a\xca\x7e\x1a\xca\x7e\x1a\xca\x7e\x1a\xca\x7e\x1a" (* ..~..~..~..~..~. *)
    ; "\xca\x7e\x1a\xca\x7e\x1a\xca\x7e\x1a\xca\x7e\x1a\xca\x7e\x1a\xca" (* .~..~..~..~..~.. *)
    ; "\x7e\x1a\xca\x7e\x1a\xca\x7e\x1a\xca\x7e\x1a\xca\x7e\x1a\xca\x7e" (* ~..~..~..~..~..~ *)
    ; "\xc8\x76\x75\x75\x75\x75\x75\x75"                                 (* .vuuuuuu *)         ] in
  Alcotest.test_case "fuzz4" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\x93\x3a\x55\x47\x12\x3a\x51\x56\x0a\x06\x80\x00") ~o ~w in
  let res = unroll_inflate decoder in
  Alcotest.(check string) "fuzz4"
    (String.concat "" expected_output) res

let fuzz5 () =
  let input =
    [ "\x93\x3a\x55\x01\x01\x01\x01\xe6\x01\x01\x01\x01\x01\x01\x01\x01" (* .:U............. *)
    ; "\x01\x01\x01\x01\x01\x00\x00"                                     (* ....... *)          ] in
  let expected_output =
    [ "\x1a\xca\x78\x78\x78\x78\x78\x78\x78\x50\x50\x37\x50\x50\x50\x50" (* ..xxxxxxxPP7PPPP *)
    ; "\x50\x50\x50\x50\x50\x50\x50\x50\x50"                             (* PPPPPPPPP *)        ] in
  Alcotest.test_case "fuzz5" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String (String.concat "" input)) ~o ~w in
  let res = unroll_inflate decoder in
  Alcotest.(check string) "fuzz5"
    (String.concat "" expected_output) res

let fuzz6 () =
  let expected_output =
    [ "\x19\x59\x59\x59\x5e\xe3\x59\x5e\xe3\x59\x5e\xe3\x59\x5e\xe3\x59" (* .YYY^.Y^.Y^.Y^.Y *)
    ; "\x5e\xe3\x33"                                                     (* ^.3 *)              ] in
  Alcotest.test_case "fuzz6" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\x93\x8c\x8c\x8c\x8c\x7b\x8c\x8c\x8c\x01\x00\x00") ~o ~w in
  Alcotest.(check decode) "fuzz6"
    (ignore @@ Inf.decode decoder ; Inf.decode decoder) `End ;
  Alcotest.(check string) "fuzz6"
    (String.concat "" expected_output) (Bigstringaf.substring o ~off:0 ~len:(Bigstringaf.length o - Inf.dst_rem decoder))

let fuzz7 () =
  Alcotest.test_case "fuzz7" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\x93\x3a\x55\x69\x12\x3a\x3f\x10\x08\x01\x00\x00") ~o ~w in
  Alcotest.(check decode) "fuzz7"
    (ignore @@ Inf.decode decoder ; Inf.decode decoder) `End ;
  Alcotest.(check string) "fuzz7"
    "\x1a\xca\x79\x34\x55\x9f\x51\x9f\x51\x9f"
    (Bigstringaf.substring o ~off:0 ~len:(Bigstringaf.length o - Inf.dst_rem decoder))

let fuzz8 () =
  Alcotest.test_case "fuzz8" `Quick @@ fun () ->
  let decoder = Inf.decoder (`String "\x7a\x37\x6d\x99\x13") ~o ~w in
  Alcotest.(check decode) "fuzz8"
    (Inf.decode decoder) (`Malformed "Unexpected end of input")

let fuzz9 () =
  Alcotest.test_case "fuzz9" `Quick @@ fun () ->
  let inputs =
    [ "\x9b\x01\x95\xfc\x51\xd2\xed\xc8\xce\xc8\xff\x80\x00\x00\x7f\xff" (* ....Q........... *)
    ; "\x79\x2f\xe9\x51\x88\x7b\xb8\x2f\xef\xa5\x8c\xf8\xf1\xb6\xce\xc8" (* y/.Q.{./........ *)
    ; "\xb8\xc8\xff\x2f\x00\x7f\x88\x7b\xbc"                             (* .../...{. *)        ] in
  let decoder = Inf.decoder (`String (String.concat "" inputs)) ~o ~w in
  Alcotest.(check decode) "fuzz9"
    (Inf.decode decoder) (`Malformed "Invalid distance")

let huffman_length_extra () =
  Alcotest.test_case "huffman length extra" `Quick @@ fun () ->
  let literals = make_literals () in
  succ_literal literals '\000' ;
  succ_literal literals '\000' ;
  succ_length literals 258 ;
  succ_length literals 256 ;
  let distances = make_distances () in
  succ_distance distances 1 ;
  succ_distance distances 1 ;
  let dynamic = Def.dynamic_of_frequencies ~literals ~distances in
  let res = encode ~block:(Def.Dynamic dynamic) [ `Literal '\000'
                                                ; `Literal '\000'
                                                ; `Copy (1, 258)
                                                ; `Copy (1, 256)
                                                ; `End ] in
  Alcotest.(check str) "encoding" res "\237\193\001\001\000\000\000@ \255W\027B\193\234\004" ;

  let decoder = Inf.decoder (`String res) ~o ~w in
  let res = unroll_inflate decoder in
  Alcotest.(check str) "result"
    (String.make (258 + 256 + 2) '\000') res

let fuzz10 () =
  Alcotest.test_case "fuzz10" `Quick @@ fun () ->
  let lst =
    [ `Literal (Char.chr 231); `Literal (Char.chr 60); `Literal (Char.chr 128)
    ; `Copy (1, 19); `End ] in
  let res = encode_dynamic lst in
  let decoder = Inf.decoder (`String res) ~o ~w in
  Alcotest.(check decode) "decoding"
    (ignore @@ Inf.decode decoder ; Inf.decode decoder) `End

let fuzz11 () =
  Alcotest.test_case "fuzz11" `Quick @@ fun () ->
  let lst =
    [ `Literal (Char.chr 228)
    ; `Literal (Char.chr 255)
    ; `Copy (1, 130)
    ; `End ] in
  let res = encode_dynamic lst in
  let decoder = Inf.decoder (`String res) ~o ~w in
  let res0 = unroll_inflate decoder in
  let res1 = Bytes.create 132 in
  Bytes.set res1 0 (Char.chr 228) ;
  Bytes.fill res1 1 131 (Char.chr 255) ;
  Alcotest.(check str) "result" res0 (Bytes.unsafe_to_string res1)

let fuzz12 () =
  Alcotest.test_case "fuzz12" `Quick @@ fun () ->
  let lst =
    [ `Literal (Char.chr 71)
    ; `Literal (Char.chr 0)
    ; `Literal (Char.chr 255)
    ; `Copy (2, 249)
    ; `End ] in
  let res = encode_dynamic lst in
  let decoder = Inf.decoder (`String res) ~o ~w in
  let res0 = unroll_inflate decoder in
  let res1 =
    [ "\x47\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00" (* G............... *)
    ; "\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00" (* ................ *)
    ; "\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00" (* ................ *)
    ; "\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00" (* ................ *)
    ; "\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00" (* ................ *)
    ; "\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00" (* ................ *)
    ; "\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00" (* ................ *)
    ; "\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00" (* ................ *)
    ; "\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00" (* ................ *)
    ; "\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00" (* ................ *)
    ; "\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00" (* ................ *)
    ; "\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00" (* ................ *)
    ; "\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00" (* ................ *)
    ; "\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00" (* ................ *)
    ; "\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00" (* ................ *)
    ; "\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00\xff\x00"                 (* ............ *)
    ] in
  Alcotest.(check str) "result" res0 (String.concat "" res1)

let fuzz13 () =
  Alcotest.test_case "fuzz13" `Quick @@ fun () ->
  let inputs =
    [ "\x9b\x0e\x02\x00"                                                 (* .... *)
    ] in
  let input = String.concat "" inputs in
  let decoder = Inf.decoder (`String input) ~o ~w in
  let res = unroll_inflate decoder in
  Alcotest.(check str) "result" res "\x97\x97\x97\x97\x97"

let fuzz14 () =
  Alcotest.test_case "fuzz14" `Quick @@ fun () ->
  let inputs =
    [ "\x0b\xff\x7f\x0c\x0c\x8f\xcd\x0e\x02\x21\x64\x0c\x04\x73\xff\x80" (* .........!d..s.. *)
    ; "\x20\x0c\x8f\x1c\x1c\x1c\x1c\x0c\x0c\x0c\x0c\x64\x1c\x7f\x0c\x0c" (*  ..........d.... *)
    ; "\x8f\xcd\x0e\x02\x21\xff\xff\x80"                                 (* ....!... *)
    ] in
  let input = String.concat "" inputs in
  let decoder = Inf.decoder (`String input) ~o ~w in
  let res = unroll_inflate decoder in
  let outputs =
    [ "\x57\xff\xc6\xff\xc6\xff\xc6\xff\xc6\x9b\x52\xc6\x9b\x52\xc6\xc6" (* W.........R..R.. *)
    ; "\x9b\x52\xc6\xc6\x9b\x52\xc6\xc6\x9b\x52\xc6\xc6\xc6\xc6\x9d\xfc" (* .R...R...R...... *)
    ; "\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc" (* ................ *)
    ; "\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc" (* ................ *)
    ; "\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc" (* ................ *)
    ; "\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc" (* ................ *)
    ; "\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc" (* ................ *)
    ; "\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc" (* ................ *)
    ; "\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc" (* ................ *)
    ; "\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc" (* ................ *)
    ; "\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc" (* ................ *)
    ; "\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc" (* ................ *)
    ; "\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc" (* ................ *)
    ; "\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc" (* ................ *)
    ; "\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc" (* ................ *)
    ; "\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc" (* ................ *)
    ; "\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc\x9d\xfc" (* ................ *)
    ; "\x9d\xfc\x9d\xfc\x9d\xfc\x53\x53\x53\x9b\x52\xc6\x9b\x52\xc6\x9b" (* ......SSS.R..R.. *)
    ; "\x52\xc6\x9b\x52\xc6\x9b\x52\xc6\x9b\x52\xc6\x9b\x52\x33\x5f\xc6" (* R..R..R..R..R3_. *)
    ; "\x5f\xc6\x5f\xc6\x5f\xc6\x9b\x52\xc6\x9b\x52\xc6\x4f\xff"         (* _._._..R..R.O. *)
    ] in
  Alcotest.(check str) "result" res (String.concat "" outputs)

let fuzz15 () =
  Alcotest.test_case "fuzz15" `Quick @@ fun () ->
  (* empty distance tree *)
  let inputs =
    [ "\x75\x85\xcd\x0e\x02\x21\x0c\x84\x3d\xf3\x14\x3d\xc2\x65\x63\xb2" (* u....!..=..=.ec. *)
    ; "\x0f\x64\xf8\x69\xdc\xc6\xc2\x12\x58\x12\xe4\xe9\x5d\xa3\x28\x26" (* .d.i....X...].(& *)
    ; "\xee\xad\xc2\x65\x63\xb2\x0f\x64\xf8\x69\xdc\xc6\xc2\x12\x58\x12" (* ...ec..d.i....X. *)
    ; "\xe4\xe9\x5d\x66\xfb\xe8\x57\x57\x18\xf3\x5b\xdd\xcb\x73"         (* ..]f..WW..[..s *)
    ] in
  let input = String.concat "" inputs in
  let decoder = Inf.decoder (`String input) ~o ~w in
  let res = unroll_inflate decoder in
  let outputs =
    [ "\x78\x20\x5f\x74\x6c\x69\x63"                                     (* x _tlic *)
    ] in
  Alcotest.(check str) "result" res (String.concat "" outputs)

let fuzz16 () =
  Alcotest.test_case "fuzz16" `Quick @@ fun () ->
  let lst = [ `Literal '@'
            ; `Copy (1, 212)
            ; `Copy (129, 258)
            ; `Copy (7, 131)
            ; `Copy (527, 208)
            ; `Copy (129, 258)
            ; `End ] in
  let res = encode_dynamic lst in
  Fmt.epr "> %S.\n%!" res ;
  let decoder = Inf.decoder (`String res) ~o ~w in
  let res = unroll_inflate decoder in
  Alcotest.(check str) "result" res (String.make 1068 '@')

let fuzz17 () =
  Alcotest.test_case "fuzz17" `Quick @@ fun () ->
  let lst = [ `Literal (Char.chr 218); `Copy (1, 21); `Literal (Char.chr 190); `Literal (Char.chr 218); `Literal (Char.chr 0); `End ] in
  let res = encode_dynamic lst in
  let decoder = Inf.decoder (`String res) ~o ~w in
  let res = unroll_inflate decoder in
  let outputs =
    [ "\xda\xda\xda\xda\xda\xda\xda\xda\xda\xda\xda\xda\xda\xda\xda\xda" (* ................ *)
    ; "\xda\xda\xda\xda\xda\xda\xbe\xda\x00"                             (* ......... *)
    ] in
  let output = String.concat "" outputs in
  Alcotest.(check str) "result" res output

let fuzz18 () =
  Alcotest.test_case "fuzz18" `Quick @@ fun () ->
  let inputs =
    [ "\x75\x8f\xcd\x0e\x02\x21\x0c\x84\x3d\xf3\x14\x3d\xfc\x54\x63\xb2" (* u....!..=..=.Tc. *)
    ; "\x0f\x64\xf8\x69\xdc\xc6\xc2\x12\x58\x12\xe4\xe9\x5d\xa3\x28\x26" (* .d.i....X...].(& *)
    ; "\xee\xad\x33\xcd\xfc\x9d\x1a\x5e\x1e\xcc\xe7\xf9\x24\x99\x40\x06" (* ..3....^....$.@. *)
    ; "\xed\x11\x4c\x56\xfb\xe8\x57\x57\x0a\xf3\x5b\xd9\xcb\x60\xd5\xd5" (* ..LV..WW..[..`.. *)
    ] in
  let input = String.concat "" inputs in
  let decoder = Inf.decoder (`String input) ~o ~w in
  let res = unroll_inflate decoder in
  let outputs =
    [ "\x75\x27\x5a\xfb\x64\x64\x2b\x63\x29\x67\x6e\x60\x20\x67\x6e\x60" (* u'dd+c)gn` gn` *)
    ; "\x20\x67\x6e\x60\x5e\x28\x20\x5d\x6e\x0a\x63\x29\x67\x6e\x60\x20" (*  gn`^( ]n.c)gn`  *)
    ; "\x67\x6e\x60\x20\x67\x6e\x63\x29\x67\x6e\x60\x20\x67\x73\x60\x69" (* gn` gnc)gn` gs`i *)
    ; "\x63"                                                             (* c *)
    ] in
  let output = String.concat "" outputs in
  Alcotest.(check str) "result" res output

let pp_cmd ppf = function
  | `Literal chr -> Fmt.pf ppf "(`Literal %02x:%a)" (Char.code chr) pp_chr chr
  | `Copy (off, len) -> Fmt.pf ppf "(`Copy (off:%d, len:%d))" off len
  | `End -> Fmt.string ppf "`End"

let eq_cmd a b = match a, b with
  | `Literal a, `Literal b -> Char.equal a b
  | `Copy (off_a, len_a), `Copy (off_b, len_b) -> off_a = off_b && len_a = len_b
  | `End, `End -> true
  | _, _ -> false

let cmd = Alcotest.testable pp_cmd eq_cmd
let cmds = Alcotest.list cmd

let lz77_0 () =
  Alcotest.test_case "simple match" `Quick @@ fun () ->
  Queue.reset q ;
  let state = Lz77.state (`String "aaaaa") ~w ~q in
  match Lz77.compress state with
  | `End ->
    let lst = Queue.to_list q in
    Alcotest.(check cmds) "result" lst [ `Literal 'a'; `Literal 'a'; `Copy (1, 3) ]
  | `Flush -> Alcotest.fail "Unexpected `Flush return"
  | `Await -> Alcotest.fail "Impossible `Await case"

let lz77_1 () =
  Alcotest.test_case "no match" `Quick @@ fun () ->
  Queue.reset q ;
  let state = Lz77.state (`String "abcde") ~w ~q in
  match Lz77.compress state with
  | `End ->
    let lst = Queue.to_list q in
    Alcotest.(check cmds) "result" lst [ `Literal 'a'
                                       ; `Literal 'b'
                                       ; `Literal 'c'
                                       ; `Literal 'd'
                                       ; `Literal 'e' ]
  | `Flush -> Alcotest.fail "Unexpected `Flush return"
  | `Await -> Alcotest.fail "Impossible `Await case"

let reconstruct lst =
  let len = List.fold_left (fun a -> function `Literal _ -> 1 + a | `Copy (_, len) -> len + a | `End -> a) 0 lst in
  let res = Bytes.create len in
  let pos = ref 0 in
  List.iter (function
      | `Literal chr -> Bytes.set res !pos chr ; incr pos
      | `Copy (off, len) ->
        for _ = 0 to len - 1
        do Bytes.set res !pos (Bytes.get res (!pos - off)) ; incr pos done
      | `End -> () (* XXX(dinosaure): should be the last *))
    lst ;
  Bytes.unsafe_to_string res

let lz77_2 () =
  Alcotest.test_case "fuzz" `Quick @@ fun () ->
  Queue.reset q ;
  let inputs =
    [ "\x40\x1e\x04\x30\x73\x00\x37\x0d\x19\x38\x63\x00\x0d\x0d\x0d\x22" (* @..0s.7..8c..... *)
    ; "\x0d\x0d\x0d\x0d\x0d\x0d\x0d\x19\x38\x80"                         (* ........8. *)
    ] in
  let input = String.concat "" inputs in
  let state = Lz77.state (`String input) ~w ~q in
  match Lz77.compress state with
  | `End ->
    let lst = Queue.to_list q in
    Fmt.epr "compressed result: @[<hov>%a@].\n%!" Fmt.(Dump.list pp_cmd) lst ;
    let res = reconstruct lst in
    Alcotest.(check str) "result" input res
  | `Flush -> Alcotest.fail "Unexpected `Flush return"
  | `Await -> Alcotest.fail "Impossible `Await case"

let lz77_3 () =
  Alcotest.test_case "fuzz" `Quick @@ fun () ->
  Queue.reset q ;
  let inputs =
    [ "\xf6\x21\xff\x7f\x00\x9d\x0d\xf6\x21\xff\x7f"                     (* .!......!.. *)
    ] in
  let input = String.concat "" inputs in
  let state = Lz77.state (`String input) ~w ~q in
  match Lz77.compress state with
  | `End ->
    let lst = Queue.to_list q in
    Fmt.epr "compressed result: @[<hov>%a@].\n%!" Fmt.(Dump.list pp_cmd) lst ;
    let res = reconstruct lst in
    Alcotest.(check str) "result" input res
  | `Flush -> Alcotest.fail "Unexpected `Flush return"
  | `Await -> Alcotest.fail "Impossible `Await case"

let lz77_4 () =
  Alcotest.test_case "fuzz" `Quick @@ fun () ->
  Queue.reset q ;
  let inputs =
    [ "\x02\x21\xf9\x1c\xf1\x9d\x0e\x02\xbc\xbc\x1c\xf9\xd9\xa3\x28\x53" (* .!............(S *)
    ; "\x53\x53\x53\x53\x53\x53\x53\x53\x53\x53\x53\x53\x53\x53\x53\x53" (* SSSSSSSSSSSSSSSS *)
    ; "\x53\x53\x53\x53\x53\x53\x53\x7f\x0e\xff\xe8\x03\x00\x00\x00\xff" (* SSSSSSS......... *)
    ; "\xff\x57\xff\xe8\x03\x00"                                         (* .W.... *)
    ] in
  let input = String.concat "" inputs in
  let state = Lz77.state (`String input) ~w ~q in
  match Lz77.compress state with
  | `End ->
    let lst = Queue.to_list q in
    Fmt.epr "compressed result: @[<hov>%a@].\n%!" Fmt.(Dump.list pp_cmd) lst ;
    let res = reconstruct lst in
    Alcotest.(check str) "result" input res
  | `Flush -> Alcotest.fail "Unexpected `Flush return"
  | `Await -> Alcotest.fail "Impossible `Await case"

let hang0 () =
  Alcotest.test_case "hang" `Quick @@ fun () ->
  let lst =
    [ `Literal '\003'; `Literal '\012'; `Copy (1, 247)
    ; `Literal 'W'; `Literal '\243'; `Copy (244, 15); `End ] in
  let res = encode_dynamic lst in
  Fmt.epr "> %S.\n%!" res ;
  let decoder = Inf.decoder (`String res) ~o ~w in
  let _ = unroll_inflate decoder in
  ()

let ( <.> ) f g = fun x -> f (g x)

let dynamic_and_fixed () =
  Alcotest.test_case "dynamic+fixed" `Quick @@ fun () ->
  let res = Buffer.create 16 in
  let literals = make_literals () in
  let distances = make_distances () in
  Queue.reset q ;
  List.iter (Queue.push_exn q <.> Queue.cmd) [ `Literal 'a'; `Copy (1, 3) ] ;
  succ_literal literals 'a' ;
  succ_length literals 3 ;
  succ_distance distances 1 ;
  let dynamic_a = Def.dynamic_of_frequencies ~literals ~distances in
  let encoder = Def.encoder (`Buffer res) ~q in
  let rec go = function
    | [] -> ()
    | `Fill lst :: r ->
      Alcotest.(check bool) "empty queue" (Queue.is_empty q) true ;
      List.iter (Queue.push_exn q <.> Queue.cmd) lst ; go r
    | #Def.encode as x :: r -> match Def.encode encoder x with
      | `Partial -> Alcotest.fail "Impossible `Partial case"
      | `Block -> Alcotest.fail "Impossible `Block case"
      | `Ok -> go r in
  go [ `Block { Def.kind= Def.Dynamic dynamic_a; Def.last= false; }
     ; `Flush
     ; `Fill [ `Literal 'b'; `Copy (1, 3); `End ]
     ; `Block { Def.kind= Def.Fixed; Def.last= true; }
     ; `Flush ] ;
  let decoder = Inf.decoder (`String (Buffer.contents res)) ~w ~o in
  let res = unroll_inflate decoder in
  Alcotest.(check str) "result" res "aaaabbbb"

let fixed_and_dynamic () =
  Alcotest.test_case "fixed+dynamic" `Quick @@ fun () ->
  let res = Buffer.create 16 in
  let literals = make_literals () in
  let distances = make_distances () in
  Queue.reset q ;
  List.iter (Queue.push_exn q <.> Queue.cmd) [ `Literal 'a'; `Copy (1, 3) ] ;
  succ_literal literals 'b' ;
  succ_length literals 3 ;
  succ_distance distances 1 ;
  let dynamic_b = Def.dynamic_of_frequencies ~literals ~distances in
  let encoder = Def.encoder (`Buffer res) ~q in
  let rec go = function
    | [] -> ()
    | `Fill lst :: r ->
      Alcotest.(check bool) "empty queue" (Queue.is_empty q) true ;
      List.iter (Queue.push_exn q <.> Queue.cmd) lst ; go r
    | #Def.encode as x :: r -> match Def.encode encoder x with
      | `Partial -> Alcotest.fail "Impossible `Partial case"
      | `Block -> Alcotest.fail "Impossible `Block case"
      | `Ok -> go r in
  go [ `Flush
     ; `Block { Def.kind= Def.Dynamic dynamic_b; last= true; }
     ; `Fill [ `Literal 'b'; `Copy (1, 3); `End ]
     ; `Flush ] ;
  Fmt.epr "> %S.\n%!" (Buffer.contents res) ;
  let decoder = Inf.decoder (`String (Buffer.contents res)) ~w ~o in
  let res = unroll_inflate decoder in
  Alcotest.(check str) "result" res "aaaabbbb"

let dynamic_and_dynamic () =
  Alcotest.test_case "dynamic+dynamic" `Quick @@ fun () ->
  let res = Buffer.create 16 in
  let literals = make_literals () in
  let distances = make_distances () in
  Queue.reset q ;
  List.iter (Queue.push_exn q <.> Queue.cmd) [ `Literal 'a'; `Copy (1, 3); `Literal 'b'; `Copy (1, 3); `End ] ;

  succ_literal literals 'a' ;
  succ_length literals 3 ;
  succ_distance distances 1 ;
  let dynamic_a = Def.dynamic_of_frequencies ~literals ~distances in
  succ_literal literals 'b' ;
  succ_length literals 3 ;
  succ_distance distances 1 ;
  let dynamic_b = Def.dynamic_of_frequencies ~literals ~distances in

  let encoder = Def.encoder (`Buffer res) ~q in
  let rec go = function
    | [] -> ()
    | x :: `Block block :: r ->
      ( match Def.encode encoder x with
        | `Partial -> Alcotest.fail "Impossible `Partial case"
        | `Block -> go ((`Block block) :: r)
        | `Ok -> Alcotest.fail "Unexpected `Ok case" )
    | x :: r -> match Def.encode encoder x with
      | `Ok -> go r
      | `Partial -> Alcotest.fail "Impossible `Partial case"
      | `Block -> Alcotest.fail "Impossible `Block case" in
  go [ `Block { Def.kind= Def.Dynamic dynamic_a; Def.last= false; }
     ; `Block { Def.kind= Def.Dynamic dynamic_b; Def.last= true; }
     ; `Flush ] ;

  Fmt.epr "> %S.\n%!" (Buffer.contents res) ;
  let decoder = Inf.decoder (`String (Buffer.contents res)) ~w ~o in
  let res = unroll_inflate decoder in
  Alcotest.(check str) "result" res "aaaabbbb"

let max_flat () =
  Alcotest.test_case "biggest flat block" `Quick @@ fun () ->
  let inputs = Bytes.make (0xFFFF + 1 + 4) '\x00' in
  Bytes.set inputs 0 '\x01' ; (* last *)
  Bytes.set inputs 1 '\xff' ; Bytes.set inputs 2 '\xff' ; (* len *)
  let decoder = Inf.decoder (`String (Bytes.unsafe_to_string inputs)) ~w ~o in
  let res = unroll_inflate decoder in
  Alcotest.(check string) "0xffff * \x00" res (String.make 0xffff '\x00')

let flat () =
  Alcotest.test_case "encode flat" `Quick @@ fun () ->
  let q = Queue.of_list [ `Literal '\xDE'; `Literal '\xAD'; `Literal '\xBE'; `Literal '\xEF' ] in
  let b = Buffer.create 16 in
  let encoder = Def.encoder (`Buffer b) ~q in

  let go = function
    | `Ok -> Buffer.contents b
    | `Partial | `Block -> assert false in
  let res0 = go (Def.encode encoder (`Block { Def.kind= Def.Flat 4; last= true; })) in
  Alcotest.(check string) "deadbeef deflated" "\x01\x04\x00\xfb\xff\xde\xad\xbe\xef" res0 ;
  let decoder = Inf.decoder (`String res0) ~w ~o in
  let res1 = unroll_inflate decoder in
  Alcotest.(check string) "deadbeef" "\xde\xad\xbe\xef" res1

let fixed_and_flat () =
  Alcotest.test_case "fixed+flat" `Quick @@ fun () ->
  let q = Queue.of_list [ `Literal 'a'; `Copy (1, 3); `End; `Literal '\xDE'; `Literal '\xAD'; `Literal '\xBE'; `Literal '\xEF' ] in
  let b = Buffer.create 16 in
  let encoder = Def.encoder (`Buffer b) ~q in

  let rec go = function
    | `Ok -> Buffer.contents b
    | `Partial -> assert false
    | `Block ->
      go (Def.encode encoder (`Block { Def.kind= Def.Flat (Queue.length q); last= true; })) in
  let res0 = go (Def.encode encoder `Flush) in
  let decoder = Inf.decoder (`String res0) ~w ~o in
  let res1 = unroll_inflate decoder in
  Alcotest.(check string) "aaaadeadbeef" "aaaa\xde\xad\xbe\xef" res1

let flat_and_fixed () =
  Alcotest.test_case "flat+fixed" `Quick @@ fun () ->
  let q = Queue.of_list [ `Literal '\xDE'; `Literal '\xAD'; `Literal '\xBE'; `Literal '\xEF'; `Literal 'a'; `Copy (1, 3); `End ] in
  let b = Buffer.create 16 in
  let encoder = Def.encoder (`Buffer b) ~q in

  let rec go = function
    | `Ok -> Buffer.contents b
    | `Partial -> assert false
    | `Block ->
      go (Def.encode encoder (`Block { Def.kind= Def.Fixed; last= true; })) in
  let res0 = go (Def.encode encoder (`Block { Def.kind= Def.Flat 4; last= false; })) in
  let decoder = Inf.decoder (`String res0) ~w ~o in
  let res1 = unroll_inflate decoder in
  Alcotest.(check string) "deadbeefaaaa" "\xde\xad\xbe\xefaaaa" res1

let load_file ln path =
  let ic = open_in path in
  let rs = Bytes.create ln in
  really_input ic rs 0 ln ;
  close_in ic ; Bytes.unsafe_to_string rs

let partial_reconstruct tmp lst =
  let len = List.fold_left (fun a -> function `Literal _ -> 1 + a | `Copy (_, len) -> len + a | `End -> a) 0 lst in
  let res = Bytes.create (String.length tmp + len) in
  Bytes.blit_string tmp 0 res 0 (String.length tmp) ;
  let pos = ref (String.length tmp) in
  List.iter (function
      | `Literal chr -> Bytes.set res !pos chr ; incr pos
      | `Copy (off, len) ->
        for _ = 0 to len - 1
        do Bytes.set res !pos (Bytes.get res (!pos - off)) ; incr pos done
      | `End -> () (* XXX(dinosaure): should be the last *))
    lst ;
  Bytes.unsafe_to_string res

let lz77_corpus_rfc5322 () =
  Alcotest.test_case "rfc5322" `Quick @@ fun () ->
  let ic = open_in "corpus/rfc5322.txt" in
  Queue.reset q ;
  let state = Lz77.state (`Channel ic) ~w ~q in
  let res = ref "" in
  let rec go () = match Lz77.compress state with
    | `Flush ->
      Alcotest.(check bool) "available q < 2" (Queue.available q < 2) true ;
      Fmt.epr "Cursor at: %d.\n%!" (String.length !res) ;
      let old = String.length !res in
      res := partial_reconstruct !res (Queue.to_list q) ;
      Fmt.epr "Commands: @[<hov>%a@].\n%!" Fmt.(Dump.list pp_cmd) (Queue.to_list q) ;
      Fmt.epr "Cursor at: %d (%d).\n%!" (String.length !res) (String.length !res - old) ;
      Alcotest.(check str) "rfc5322.txt" (load_file (String.length !res) "corpus/rfc5322.txt") !res ;
      Queue.reset q ; go ()
    | `Await -> Alcotest.fail "Impossible `Await case"
    | `End ->
      res := partial_reconstruct !res (Queue.to_list q) ;
      Alcotest.(check str) "rfc5322.txt" (load_file (String.length !res) "corpus/rfc5322.txt") !res ;
      close_in ic in
  go ()

let _max_bits = 15
let _literals = 256
let _length_codes = 29
let _l_codes = _literals + 1 + _length_codes

let tree_0 () =
  Alcotest.test_case "empty literals/lengths freqs" `Quick @@ fun () ->
  let literals = make_literals () in
  let literals = (literals :> int array) in
  let bl_count = Array.make (_max_bits + 1) 0 in
  let tree = T.make ~length:_l_codes literals ~bl_count in
  let lengths = ref [] in
  let codes = ref [] in
  Array.iteri (fun n -> function
      | 0 -> ()
      | l -> lengths := (n, l) :: !lengths ;
        let l', c = Lookup.get tree.T.tree n in
        Alcotest.(check int) "check length" l l' ;
        codes := (n, c) :: !codes )
    tree.T.lengths ;
  let lengths = List.sort (fun (a, _) (b, _) -> a - b) !lengths in
  let codes = List.sort (fun (a, _) (b, _) -> a - b) !codes in
  Alcotest.(check (list (pair int int)))
    "lengths" lengths [ (0, 1); (256, 1) ] ;
  Alcotest.(check (list (pair int int)))
    "codes" codes [ (0, 0); (256, 1) ]

let tree_rfc5322_corpus () =
  Alcotest.test_case "rfc5322 corpus literals/lengths freqs" `Quick @@ fun () ->
  (* XXX(dinosaure): this is a dump of [literals] when we compute [rfc5322.txt].
     Values are close to LZ77 algorithm/implementation and it's why I dumped it.
     This test want to check if we generate the same literals/lengths tree than [zlib]. *)
  let literals =
    [|     0;    0;    0;    0;    0;    0;     0;    0;      0;    0;  236;   0;  27;   0;    0;  0;   0; 0;
           0;    0;    0;    0;    0;    0;     0;    0;      0;    0;    0;   0;   0;   0; 5446;  1; 311; 1;
           1;   10;    1;    7;  127;  128;    30;   11;    273;  175; 1180;  73;  67; 111;
         169;  137;   60;   66;   45;   26;    41;   37;     57;   32;    6;  44;   6;   1;    7;
          96;   21;  115;   61;   32;  127;     9;   45;    108;    3;    2;  66;  66;  46;   81;
          31;    7;  104;  169;  118;   60;     3;   49;      1;    5;    0;  54;   9;  74;    1;  1;
           1; 2126;  318; 1060; 1119; 3330;   666;  377;    800; 2005;    9;  81;
         970;  729; 1808; 1802;  615;   40;  1612; 1991;   2201;  537;  158;
         251;  127;  389;   12;    1;   62;     1;    1;      0;    0;    0;   0;   0;   0;    0;  0;   0;
           0;    0;    0;    0;    0;    0;     0;    0;      0;    0;    0;   0;   0;   0;    0;  0;   0; 0; 0;
           0;    0;    0;    0;    0;    0;     0;    0;      0;    0;    0;   0;   0;   0;    0;  0;   0; 0; 0;
           0;    0;    0;    0;    0;    0;     0;    0;      0;    0;    0;   0;   0;   0;    0;  0;   0; 0; 0;
           0;    0;    0;    0;    0;    0;     0;    0;      0;    0;    0;   0;   0;   0;    0;  0;   0; 0; 0;
           0;    0;    0;    0;    0;    0;     0;    0;      0;    0;    0;   0;   0;   0;    0;  0;   0; 0; 0;
           0;    0;    0;    0;    0;    0;     0;    0;      0;    0;    0;   0;   0;   0;    0;  0;   0; 0; 0;
           0;    0;    0;    0;    0;    0;     1;  1594;  1153;  698;  345; 326; 229; 150;
         107;  172;  111;   97;   23;  100;    44;    24;    10;   20;   14;   3;   7;  17;
           1;    1;    1;    0;    0;    0;     0;     0;     2;    2;    2;   2;   2;   2;    2;  2;   3; 4; 4;
           4;    5;    6;    7;    8;    9;    10;    13;    14;   14;   15;  18;  18;  20;   23; 27;
          28;   31;   35;   37;   39;   47;    48;    55;    57;   59;   66;  73;  75;  77;   80;
          82;   90;   95;  103;  110;  115;   119;   124;   128;  132;  140; 144;
         152;  162;  180;  183;  190;  196;   204;   212;   219;  230;  239; 241;
         252;  263;  278;  284;  300;  311;   324;   363;   384;  400;  425; 444;
         469;  485;  515;  559;  565;  591;   619;   655;   711;  784;  869; 954;
        1000; 1109; 1145; 1210; 1279; 1366;  1510;  1740;  1922; 1972;
        2121; 2298; 2489; 2773; 2936; 3206;  3519;  3702;  3886; 4093;
        4787; 5709; 6198; 7221; 7979; 9758; 11907; 15200; 21665;
       36865;    0;    0;    0;    0;    0;     0;     0;     0;    0;    0;   0;   0;   0;    0;  0;   0; 0;
           0;    0;    0;    0;    0;    0;     0;     0;     0;    0;    0;   0;   0;   0;    0;  0;   0; 0; 0;
           0;    0;    0;    0;    0;    0;     0;     0;     0;    0;    0;   0;   0;   0;    0;  0;   0; 0; 0;
           0;    0;    0;    0;    0;    0;     0;     0;     0;    0;    0;   0;   0;   0;    0;  0;   0; 0; 0;
           0;    0;    0;    0;    0;    0;     0;     0;     0;    0;    0;   0;   0;   0;    0;  0;   0; 0; 0;
           0;    0;    0;    0;    0;    0;     0;     0;     0;    0;    0;   0;   0;   0;    0;  0;   0; 0; 0;
           0;    0;    0;    0;    0;    0;     0;     0;     0;    0;    0;   0;   0;   0;    0;  0;   0; 0; 0;
           0;    0;    0;    0;    0;    0;     0;     0;     0;    0;    0;   0;   0;   0;    0;  0;   0; 0; 0;
           0;    0;    0;    0;    0;    0;     0;     0;     0;    0;    0;   0;   0;   0;    0;  0;   0; |] in
  Alcotest.(check int) "length of freqs" (2 * _l_codes + 1) (Array.length literals) ;
  let bl_count = Array.make (_max_bits + 1) 0 in
  let ltree = T.make ~length:_l_codes literals ~bl_count in
  let len_6, code_6 = Lookup.get ltree.T.tree (Char.code '6') in
  let len_eob, code_eob = Lookup.get ltree.T.tree 256 in
  Alcotest.(check (pair int int)) "literal 6" (10, 0x35f) (len_6, code_6) ;
  Alcotest.(check (pair int int)) "eob" (15, 0x6fff) (len_eob, code_eob)

let w0 = make_window ~bits:15
let w1 = make_window ~bits:15
let s = bigstring_create io_buffer_size
let o = bigstring_create io_buffer_size
let q = Queue.create (2 * 2 * 4096)
let b = Buffer.create 4096

let compress_and_uncompress ic =
  let state = Lz77.state (`Channel ic) ~w:w0 ~q in
  let kind = ref Def.Fixed in
  let encoder = Def.encoder `Manual ~q in
  let decoder = Inf.decoder `Manual ~w:w1 ~o in

  Buffer.clear b ;
  Queue.reset q ;
  Def.dst encoder s 0 io_buffer_size ;

  let rec partial k = function
    | `Await ->
      k @@ Def.encode encoder `Await
    | `End ->
      for i = 0 to io_buffer_size - Inf.dst_rem decoder - 1
      do Buffer.add_char b (Char.unsafe_chr (unsafe_get_uint8 o i)) done
    | `Flush ->
      for i = 0 to io_buffer_size - Inf.dst_rem decoder - 1
      do Buffer.add_char b (Char.unsafe_chr (unsafe_get_uint8 o i)) done ;
      Inf.flush decoder ;
      Def.dst encoder s 0 io_buffer_size ;
      partial k @@ Inf.decode decoder
    | `Malformed err ->
      invalid_arg err
  and compress () = match Lz77.compress state with
    | `Await -> assert false
    | `End ->
      Queue.push_exn q Queue.eob ;
      pending @@ Def.encode encoder (`Block { Def.kind= Def.Fixed; last= true; })
    | `Flush ->
      kind := Def.Dynamic (Def.dynamic_of_frequencies ~literals:(Lz77.literals state) ~distances:(Lz77.distances state)) ;
      encode @@ Def.encode encoder (`Block { Def.kind= !kind; last= false; })
  and encode = function
    | `Partial ->
      let len = io_buffer_size - Def.dst_rem encoder in
      Inf.src decoder s 0 len ;
      partial encode @@ Inf.decode decoder
    | `Ok -> compress ()
    | `Block ->
      kind := Def.Dynamic (Def.dynamic_of_frequencies ~literals:(Lz77.literals state) ~distances:(Lz77.distances state)) ;
      encode @@ Def.encode encoder (`Block { Def.kind= !kind; last= false; })
  and pending = function
    | `Partial ->
      let len = io_buffer_size - Def.dst_rem encoder in
      Inf.src decoder s 0 len ;
      partial pending @@ Inf.decode decoder
    | `Ok -> last @@ Def.encode encoder `Flush
    | `Block -> assert false
  and last = function
    | `Partial ->
      let len = io_buffer_size - Def.dst_rem encoder in
      Inf.src decoder s 0 len ;
      partial pending @@ Inf.decode decoder
    | `Ok -> partial pending @@ Inf.decode decoder
    | `Block -> assert false in

  compress () ; Stdlib.seek_in ic 0 ;
  let contents = Buffer.contents b in

  let rec slow_compare pos =
    match input_char ic with
    | chr ->
      if pos >= String.length contents then Fmt.invalid_arg "Reach end of contents" ;
      if contents.[pos] <> chr
      then Fmt.invalid_arg "Contents differ at %08x\n%!" pos ; slow_compare (succ pos)
    | exception End_of_file ->
      if pos <> String.length contents
      then Fmt.invalid_arg "Lengths differ: (contents: %d, file: %d)" (String.length contents) pos in

  slow_compare 0

let test_corpus filename =
  Alcotest.test_case filename `Slow @@ fun () ->
  let ic = open_in Filename.(concat "corpus" filename) in
  compress_and_uncompress ic ; close_in ic

let gzip_compress_and_uncompress ~filename ic =
  De.Queue.reset q ;
  let os = bigstring_create io_buffer_size in
  let bf = Buffer.create 4096 in
  let encoder = Gz.Def.encoder (`Channel ic) `Manual ~filename ~mtime:0l Gz.Unix ~q ~w ~level:0 in
  let decoder = Gz.Inf.decoder `Manual ~o in

  let rec go_encode decoder encoder = match Gz.Def.encode encoder with
    | `Await _ -> assert false
    | `Flush encoder ->
      let len = io_buffer_size - Gz.Def.dst_rem encoder in
      Fmt.epr "[!] [`Flush] >>> (dst-rem: %d) %d byte(s).\n%!" (Gz.Def.dst_rem encoder) len ;
      go_decode (Gz.Inf.src decoder os 0 len) encoder
    | `End encoder ->
      let len = io_buffer_size - Gz.Def.dst_rem encoder in
      Fmt.epr "[!] [`End] >>> %d byte(s).\n%!" len ;
      go_decode (Gz.Inf.src decoder os 0 len) encoder
  and go_decode decoder encoder = match Gz.Inf.decode decoder with
    | `Await decoder ->
      Fmt.epr "[!] [decode] `Await.\n%!" ;
      go_encode decoder (Gz.Def.dst encoder os 0 io_buffer_size)
    | `Flush decoder ->
      Fmt.epr "[!] [decode] `Flush.\n%!" ;
      let len = io_buffer_size - Gz.Inf.dst_rem decoder in
      for i = 0 to pred len do Buffer.add_char bf o.{i} done ;
      go_decode (Gz.Inf.flush decoder) encoder
    | `End decoder ->
      Fmt.epr "[!] [decode] `End.\n%!" ;
      let len = io_buffer_size - Gz.Inf.dst_rem decoder in
      for i = 0 to pred len do Buffer.add_char bf o.{i} done ;
      Alcotest.(check (option string)) "filename" (Gz.Inf.filename decoder) (Some filename) ;
      Buffer.contents bf
    | `Malformed err -> failwith err in

  let contents = go_decode decoder encoder in
  seek_in ic 0 ;

  let rec slow_compare pos =
    match input_char ic with
    | chr ->
      if pos >= String.length contents
      then Fmt.invalid_arg "Reach end of contents" ;
      if contents.[pos] <> chr
      then Fmt.invalid_arg "Contents differ at %08x\n%!" pos ; slow_compare (succ pos)
    | exception End_of_file ->
      if pos <> String.length contents
      then Fmt.invalid_arg "Lengths differ: (contents: %d, file: %d)" (String.length contents) pos in

  slow_compare 0

let zlib_compress_and_uncompress ic =
  De.Queue.reset q ;
  let encoder = Zl.Def.encoder (`Channel ic) `Manual ~q ~w ~level:0 in
  let decoder = Zl.Inf.decoder `Manual ~o ~allocate:(fun bits -> De.make_window ~bits) in
  let os = De.bigstring_create io_buffer_size in
  let bf = Buffer.create 4096 in

  let rec go_encode decoder encoder = match Zl.Def.encode encoder with
    | `Await _ -> assert false
    | `Flush encoder ->
      let len = io_buffer_size - Zl.Def.dst_rem encoder in
      go_decode (Zl.Inf.src decoder os 0 len) encoder
    | `End encoder ->
      let len = io_buffer_size - Zl.Def.dst_rem encoder in
      go_decode (Zl.Inf.src decoder os 0 len) encoder
  and go_decode decoder encoder = match Zl.Inf.decode decoder with
    | `Await decoder ->
      go_encode decoder (Zl.Def.dst encoder os 0 io_buffer_size)
    | `Flush decoder ->
      let len = io_buffer_size - Zl.Inf.dst_rem decoder in
      for i = 0 to pred len do Buffer.add_char bf o.{i} done ;
      go_decode (Zl.Inf.flush decoder) encoder
    | `End decoder ->
      let len = io_buffer_size - Zl.Inf.dst_rem decoder in
      for i = 0 to pred len do Buffer.add_char bf o.{i} done ;
      Buffer.contents bf
    | `Malformed err -> failwith err in

  let contents = go_decode decoder encoder in
  seek_in ic 0 ;

  let rec slow_compare pos =
    match input_char ic with
    | chr ->
      if pos >= String.length contents
      then Fmt.invalid_arg "Reach end of contents" ;
      if contents.[pos] <> chr
      then Fmt.invalid_arg "Contents differ at %08x\n%!" pos ; slow_compare (succ pos)
    | exception End_of_file ->
      if pos <> String.length contents
      then Fmt.invalid_arg "Lengths differ: (contents: %d, file: %d)" (String.length contents) pos in

  slow_compare 0

let test_corpus_with_zlib filename =
  Alcotest.test_case filename `Slow @@ fun () ->
  let ic = open_in Filename.(concat "corpus" filename) in
  zlib_compress_and_uncompress ic ; close_in ic

let test_corpus_with_gzip filename =
  Alcotest.test_case filename `Slow @@ fun () ->
  let ic = open_in Filename.(concat "corpus" filename) in
  gzip_compress_and_uncompress ~filename ic ; close_in ic

let git_object () =
  (* XXX(dinosaure): Flat DEFLATE block where inputs.(0) must not do a [Window.update]. *)
  Alcotest.test_case "git object" `Quick @@ fun () ->
  let inputs =
    [ "\x78\x01\x01\x1e\x00\xe1\xff"
    ; "\x9d\x02\x9d\x02\x90\xad\x14\x72\xb9\xb4\x44\x59\x5d\x21\x05\xb7\
       \x34\x4f\x64\xe9\xa8\x5a\x3e\xd9\x91\x1f\x44\x91\xc1\x5c\xbd\xe5\
       \x0c\xd1" ] in
  let decoder = Zl.Inf.decoder (`String (String.concat "" inputs)) ~o ~allocate:(fun _ -> w) in
  let rec go decoder = match Zl.Inf.decode decoder with
    | `Await _ -> assert false | `Flush decoder -> go (Zl.Inf.flush decoder) | `Malformed err -> failwith err | `End _ -> () in
  go decoder ;
  let[@warning "-8"] [ i0; i1; ] = List.map (fun x -> Bigstringaf.of_string ~off:0 ~len:(String.length x) x) inputs in
  let decoder = Zl.Inf.decoder `Manual ~o ~allocate:(fun _ -> w) in
  let decoder = Zl.Inf.src decoder i0 0 (Bigstringaf.length i0) in
  let rec go_i0 decoder = match Zl.Inf.decode decoder with
    | `Await decoder ->
      let decoder = Zl.Inf.src decoder i1 0 (Bigstringaf.length i1) in
      go_i1 decoder
    | `Flush decoder ->
      let decoder = Zl.Inf.flush decoder in
      go_i0 decoder
    | `Malformed err -> failwith err
    | `End _ -> Fmt.failwith "Unexpected end of flow"
  and go_i1 decoder = match Zl.Inf.decode decoder with
    | `Await _ -> Fmt.failwith "Unexpected `Await case"
    | `Flush decoder -> let decoder = Zl.Inf.flush decoder in go_i1 decoder
    | `Malformed err -> failwith err
    | `End _ -> () in
  go_i0 decoder

let emitter_from_string x =
  let pos = ref 0 in
  (fun i ->
     let len = min (String.length x - !pos) (Bigstringaf.length i) in
     Bigstringaf.blit_from_string x ~src_off:!pos i ~dst_off:0 ~len ;
     pos := !pos + len ; len)

let producer_to_string () =
  let buf = Buffer.create 0x100 in
  (fun o len -> Buffer.add_string buf (Bigstringaf.substring o ~off:0 ~len)),
  (fun () -> Buffer.contents buf)

let failwith_on_error_msg = function
  | Ok v -> v
  | Error (`Msg err) -> failwith err

let higher_zlib input =
  Alcotest.test_case "higher" `Quick @@ fun () ->
  Queue.reset q ;
  let refill = emitter_from_string input in
  let flush, contents = producer_to_string () in
  Zl.Higher.compress ~level:0 ~w ~q ~i ~o ~refill ~flush ;
  Fmt.epr "%S\n%!" (contents ()) ;
  let refill = emitter_from_string (contents ()) in
  let flush, contents = producer_to_string () in
  let res = Zl.Higher.uncompress ~allocate:(fun _ -> w) ~i ~o ~refill ~flush in
  failwith_on_error_msg res ;
  Alcotest.(check string) "higher" input (contents ())

let higher_zlib0 () = higher_zlib "aaaa"
let higher_zlib1 () = higher_zlib "bbbb"
let higher_zlib2 () = higher_zlib "abcd"
let higher_zlib3 () = higher_zlib "Le diable me remet dans le mal"

let test_multiple_flush_zlib () =
  Alcotest.test_case "multiple flush zlib" `Quick @@ fun () ->
  Queue.reset q ;
  let refill = emitter_from_string "foo" in
  let flush, contents = producer_to_string () in
  Zl.Higher.compress ~level:0 ~w ~q ~i ~o ~refill ~flush ;
  let input = contents () in
  let decoder = Zl.Inf.decoder (`String input) ~o ~allocate:(fun bits -> De.make_window ~bits) in
  let decoder = match Zl.Inf.decode decoder with
    | `Flush decoder -> decoder
    | _ -> Alcotest.failf "Invalid first call to Zl.Inf.decode" in
  let decoder = match Zl.Inf.decode decoder with
    | `Flush decoder -> decoder
    | _ -> Alcotest.failf "Invalid second call to Zl.Inf.decode" in
  let decoder = match Zl.Inf.decode decoder with
    | `Flush decoder ->
      let foo = Bigstringaf.substring o ~off:0 ~len:(Bigstringaf.length o - Zl.Inf.dst_rem decoder) in
      Alcotest.(check string) "contents" foo "foo" ;
      Zl.Inf.flush decoder
    | _ -> Alcotest.failf "Invalid third call to Zl.Inf.decode" in
  match Zl.Inf.decode decoder with
  | `End _ -> Alcotest.(check pass) "inflated" () ()
  | _ -> Alcotest.failf "Invalid last call to Zl.Inf.decode"

let test_empty_with_zlib () =
  Alcotest.test_case "empty zlib" `Quick @@ fun () ->
  Queue.reset q ;
  let buf = Buffer.create 16 in
  let encoder = Zl.Def.encoder (`String "") (`Buffer buf) ~q ~w ~level:3 in
  let go encoder = match Zl.Def.encode encoder with
    | `Flush _ | `Await _ -> Alcotest.failf "Unexpected `Flush or `Await signal"
    | `End _ -> Buffer.contents buf in
  let zl = go encoder in
  Fmt.epr ">>> @[<hov>%a@]\n%!" (Hxd_string.pp Hxd.O.default) zl ;
  let decoder = Zl.Inf.decoder (`String zl) ~o ~allocate:(fun bits -> De.make_window ~bits) in
  match Zl.Inf.decode decoder with
  | `Await _ -> Alcotest.failf "Unexpected `Await signal"
  | `Flush _ -> Alcotest.failf "Unexpected `Flush signal"
  | `End decoder ->
    Alcotest.(check int) "empty" (bigstring_length o - Zl.Inf.dst_rem decoder) 0
  | `Malformed err -> Alcotest.failf "Malformed Zlib: %s" err

let test_empty_with_zlib_and_small_output () =
  Alcotest.test_case "empty zlib & small output" `Quick @@ fun () ->
  Queue.reset q ;
  let o = bigstring_create 4 in
  let buf = Buffer.create 16 in
  let encoder = Zl.Def.encoder (`String "") `Manual ~q ~w ~level:3 in
  let encoder = Zl.Def.dst encoder o 0 4 in
  let rec go encoder = match Zl.Def.encode encoder with
    | `Flush encoder ->
      let len = bigstring_length o - Zl.Def.dst_rem encoder in
      let raw = Bigstringaf.substring o ~off:0 ~len in
      Buffer.add_string buf raw ;
      go (Zl.Def.dst encoder o 0 4)
    | `Await _ -> Alcotest.failf "Unexpected `Await signal"
    | `End _ ->
      Alcotest.(check int) "empty trailer" (bigstring_length o - Zl.Def.dst_rem encoder) 0 ;
      Buffer.contents buf in
  let zl = go encoder in
  Fmt.epr ">>> @[<hov>%a@].\n%!" (Hxd_string.pp Hxd.O.default) zl ;
  let decoder = Zl.Inf.decoder (`String zl) ~o ~allocate:(fun bits -> De.make_window ~bits) in
  match Zl.Inf.decode decoder with
  | `Await _ -> Alcotest.failf "Unexpected `Await signal"
  | `Flush _ -> Alcotest.failf "Unexpected `Flush signal"
  | `End decoder ->
    Alcotest.(check int) "empty" (bigstring_length o - Zl.Inf.dst_rem decoder) 0
  | `Malformed err -> Alcotest.failf "Malformed Zlib: %s" err

let test_empty_with_zlib_byte_per_byte () =
  Alcotest.test_case "empty zlib (byte per byte)" `Quick @@ fun () ->
  Queue.reset q ;
  let buf = Buffer.create 16 in
  let encoder = Zl.Def.encoder (`String "") (`Buffer buf) ~q ~w ~level:3 in
  let go encoder = match Zl.Def.encode encoder with
    | `Flush _ | `Await _ -> Alcotest.failf "Unexpected `Flush or `Await signal"
    | `End _ -> Buffer.contents buf in
  let zl = go encoder in
  let decoder = Zl.Inf.decoder `Manual ~o ~allocate:(fun bits -> De.make_window ~bits) in
  let i = Bigstringaf.create 1 in
  Bigstringaf.blit_from_string zl ~src_off:0 i ~dst_off:0 ~len:1 ;
  let decoder = Zl.Inf.src decoder i 0 1 in
  let rec go decoder (buf, off, len) = match Zl.Inf.decode decoder with
    | `Flush _ -> Alcotest.failf "Unexpected `Flush signal"
    | `Await decoder ->
      if len > 0 then
      ( Bigstringaf.blit_from_string buf ~src_off:off i ~dst_off:0 ~len:1
      ; let decoder = Zl.Inf.src decoder i 0 1 in
        Fmt.epr ">>> REFILL (off: %d, len: %d).\n%!" off len
      ; go decoder (buf, succ off, len - 1) )
      else ( Fmt.epr ">>> END OF INPUT.\n%!" ; go (Zl.Inf.src decoder i 0 0 ) (buf, off, len) )
    | `End decoder ->
      Alcotest.(check int) "empty" (bigstring_length o - Zl.Inf.dst_rem decoder) 0
    | `Malformed err -> Alcotest.failf "Malformed Zlib: %s" err in
  go decoder (zl, 1, String.length zl - 1)

let test_empty_gzip () =
  Alcotest.test_case "empty GZip" `Quick @@ fun () ->
  let input =
    [ "\x1f\x8b\x08\x00\x82\xe5\x53\x5e\x00\x03\x03\x00\x00\x00\x00\x00"
    ; "\x00\x00\x00\x00" ] in
  let decoder = Gz.Inf.decoder (`String (String.concat "" input)) ~o in
  match Gz.Inf.decode decoder with
  | `Await _ -> Alcotest.failf "Unexpected `Await signal"
  | `Flush _ -> Alcotest.failf "Unexpected `Flush signal"
  | `End decoder ->
    Alcotest.(check int) "empty GZip" (Gz.Inf.dst_rem decoder - bigstring_length o) 0
  | `Malformed err -> Alcotest.failf "Malformed GZip: %s" err

let test_empty_gzip_with_name () =
  Alcotest.test_case "empty GZip with name" `Quick @@ fun () ->
  let input =
    [ "\x1f\x8b\x08\x08\xa6\xec\x53\x5e\x00\x03\x74\x65\x73\x74\x00\x03"
    ; "\x00\x00\x00\x00\x00\x00\x00\x00\x00" ] in
  let decoder = Gz.Inf.decoder (`String (String.concat "" input)) ~o in
  match Gz.Inf.decode decoder with
  | `Await _ -> Alcotest.failf "Unexpected `Await signal"
  | `Flush _ -> Alcotest.failf "Unexpected `Flush signal"
  | `End decoder ->
    Alcotest.(check int) "empty GZip" (Gz.Inf.dst_rem decoder - bigstring_length o) 0 ;
    Alcotest.(check (option string)) "name" (Gz.Inf.filename decoder) (Some "test")
  | `Malformed err -> Alcotest.failf "Malformed GZip: %s" err

let test_foo_gzip () =
  Alcotest.test_case "foo GZip" `Quick @@ fun () ->
  let input =
    [ "\x1f\x8b\x08\x08\x2d\xf1\x53\x5e\x00\x03\x66\x6f\x6f\x00\x4b\xcb"
    ; "\xcf\x07\x00\x21\x65\x73\x8c\x03\x00\x00\x00" ] in
  let decoder = Gz.Inf.decoder (`String (String.concat "" input)) ~o in
  let decoder = match Gz.Inf.decode decoder with
      | `Await _ -> Alcotest.failf "Unexpected `Await signal"
      | `End _ -> Alcotest.failf "Unexpected `End signal"
      | `Flush decoder ->
        let foo = Bigstringaf.substring o ~off:0 ~len:(Bigstringaf.length o - Gz.Inf.dst_rem decoder) in
        Alcotest.(check string) "contents" "foo" foo ;
        Gz.Inf.flush decoder
      | `Malformed err -> Alcotest.failf "Malformed GZip: %s" err in
  match Gz.Inf.decode decoder with
  | `Await _ -> Alcotest.failf "Unexpected `Await signal"
  | `Flush _ -> Alcotest.failf "Unexpected `Flush signal"
  | `End decoder ->
    Alcotest.(check (option string)) "name" (Gz.Inf.filename decoder) (Some "foo")
  | `Malformed err -> Alcotest.failf "Malformed GZip: %s" err

let test_multiple_flush_gzip () =
  Alcotest.test_case "multiple flush GZip" `Quick @@ fun () ->
  let input =
    [ "\x1f\x8b\x08\x08\x2d\xf1\x53\x5e\x00\x03\x66\x6f\x6f\x00\x4b\xcb"
    ; "\xcf\x07\x00\x21\x65\x73\x8c\x03\x00\x00\x00" ] in
  let decoder = Gz.Inf.decoder (`String (String.concat "" input)) ~o in
  let decoder = match Gz.Inf.decode decoder with
    | `Flush decoder -> decoder
    | _ -> Alcotest.failf "Invalid first call to Gz.Inf.decode" in
  let decoder = match Gz.Inf.decode decoder with
    | `Flush decoder -> decoder
    | _ -> Alcotest.failf "Invalid second call to Gz.Inf.decode" in
  let decoder = match Gz.Inf.decode decoder with
    | `Flush decoder ->
      let foo = Bigstringaf.substring o ~off:0 ~len:(Bigstringaf.length o - Gz.Inf.dst_rem decoder) in
      Alcotest.(check (option string)) "name" (Gz.Inf.filename decoder) (Some "foo") ;
      Alcotest.(check string) "contents" foo "foo" ;
      Gz.Inf.flush decoder
    | _ -> Alcotest.failf "Invalid third call to Gz.Inf.decode" in
  match Gz.Inf.decode decoder with
  | `End _ -> Alcotest.(check pass) "inflated" () ()
  | `Malformed err -> Alcotest.failf "Malformed GZip: %s" err
  | _ -> Alcotest.failf "Invalid last call to Gz.Inf.decode"

let test_generate_empty_gzip () =
  Alcotest.test_case "generate empty GZip" `Quick @@ fun () ->
  Queue.reset q ;
  let buf = Buffer.create 16 in
  let encoder = Gz.Def.encoder (`String "") (`Buffer buf) ~mtime:0l Gz.Unix ~q ~w ~level:3 in
  let rec go encoder = match Gz.Def.encode encoder with
    | `Await _ -> Alcotest.failf "Unexpected `Await signal"
    | `Flush _ -> Alcotest.failf "Unexpected `Flush signal"
    | `End _ -> Buffer.contents buf in
  let gz = go encoder in
  Fmt.epr ">>> @[<hov>%a@].\n%!" (Hxd_string.pp Hxd.O.default) gz ;
  let decoder = Gz.Inf.decoder (`String gz) ~o in
  match Gz.Inf.decode decoder with
  | `Flush _ -> Alcotest.failf "Unexpected `Flush signal"
  | `Await _ -> Alcotest.failf "Unexpected `Await signal"
  | `End decoder ->
    Alcotest.(check int) "empty GZip" (bigstring_length o - Gz.Inf.dst_rem decoder) 0
  | `Malformed err -> Alcotest.failf "Malformed GZip: %s" err

let test_generate_empty_gzip_with_name () =
  Alcotest.test_case "generate empty GZip with name" `Quick @@ fun () ->
  Queue.reset q ;
  let buf = Buffer.create 16 in
  let encoder = Gz.Def.encoder (`String "") (`Buffer buf) ~filename:"foo" ~mtime:0l Gz.Unix ~q ~w ~level:0 in
  let rec go encoder = match Gz.Def.encode encoder with
    | `Await _ -> Alcotest.failf "Unexpected `Await signal"
    | `Flush _ -> Alcotest.failf "Unexpected `Flush signal"
    | `End _ -> Buffer.contents buf in
  let gz = go encoder in
  Fmt.epr ">>> @[<hov>%a@].\n%!" (Hxd_string.pp Hxd.O.default) gz ;
  let decoder = Gz.Inf.decoder (`String gz) ~o in
  match Gz.Inf.decode decoder with
  | `Flush _ -> Alcotest.failf "Unexpected `Flush signal"
  | `Await _ -> Alcotest.failf "Unexpected `Await signal"
  | `End decoder ->
    Alcotest.(check int) "emtpy GZip" (bigstring_length o - Gz.Inf.dst_rem decoder) 0 ;
    Alcotest.(check (option string)) "foo" (Gz.Inf.filename decoder) (Some "foo")
  | `Malformed err -> Alcotest.failf "Malformed GZip: %s" err

let test_generate_foo_gzip () =
  Alcotest.test_case "generate foo GZip" `Quick @@ fun () ->
  Queue.reset q ;
  let buf = Buffer.create 16 in
  let encoder = Gz.Def.encoder (`String "foo") (`Buffer buf) ~filename:"foo" ~mtime:0l Gz.Unix ~q ~w ~level:0 in
  let rec go encoder = match Gz.Def.encode encoder with
    | `Await _ -> Alcotest.failf "Unexpected `Await signal"
    | `Flush _ -> Alcotest.failf "Unexpected `Flush signal"
    | `End _ -> Buffer.contents buf in
  let gz = go encoder in
  Fmt.epr ">>> @[<hov>%a@].\n%!" (Hxd_string.pp Hxd.O.default) gz ;
  let decoder = Gz.Inf.decoder (`String gz) ~o in
  let decoder = match Gz.Inf.decode decoder with
    | `Await _ | `End _ -> Alcotest.failf "Unexpected `Await or `End signal"
    | `Flush decoder ->
      let len = bigstring_length o - Gz.Inf.dst_rem decoder in
      let raw = Bigstringaf.substring o ~off:0 ~len in
      Alcotest.(check string) "contents" raw "foo" ;
      Gz.Inf.flush decoder
    | `Malformed err -> Alcotest.failf "Malformed GZip: %s" err in
  match Gz.Inf.decode decoder with
  | `Flush _ -> Alcotest.failf "Unexpected `Flush signal"
  | `Await _ -> Alcotest.failf "Unexpected `Await signal"
  | `End decoder ->
    Alcotest.(check pass) "GZip terminate" () ()
  | `Malformed err -> Alcotest.failf "Malformed GZip: %s" err

let test_with_camlzip () =
  Alcotest.test_case "compare with camlzip" `Quick @@ fun () ->
  let oc = open_out "foo.gz" in
  let encoder = Gz.Def.encoder (`String "foo") (`Channel oc) ~filename:"foo.gz" ~mtime:0l Gz.Unix ~q ~w ~level:0 in
  let rec go encoder = match Gz.Def.encode encoder with
    | `Await _ -> Alcotest.failf "Unexpected `Await signal"
    | `Flush _ -> Alcotest.failf "Unexpected `Flush signal"
    | `End _ -> close_out oc in
  go encoder ;
  let ic = Gzip.open_in "foo.gz" in
  let rs = Bytes.create 0x1000 in
  let ln = Gzip.input ic rs 0 0x1000 in
  Alcotest.(check string) "contents" (Bytes.sub_string rs 0 ln) "foo" ;
  Gzip.close_in ic
;;

let test_gzip_hcrc () =
  Alcotest.test_case "test header crc" `Quick @@ fun () ->
  let oc = open_out "foo.gz" in
  let encoder = Gz.Def.encoder (`String "foo & bar") (`Channel oc) ~filename:"foo.gz" ~mtime:0l Gz.Unix ~hcrc:true ~q ~w ~level:0 in
  let rec go encoder = match Gz.Def.encode encoder with
    | `Await _ -> Alcotest.failf "Unexpected `Await signal"
    | `Flush _ -> Alcotest.failf "Unexpected `Flush signal"
    | `End _ -> close_out oc in
  go encoder ;
  let ic = open_in "foo.gz" in
  let decoder = Gz.Inf.decoder (`Channel ic) ~o in
  let decoder = match Gz.Inf.decode decoder with
    | `Await _ | `End _ -> Alcotest.failf "Unexpected `Await or `End signal"
    | `Flush decoder ->
      let len = bigstring_length o - Gz.Inf.dst_rem decoder in
      let raw = Bigstringaf.substring o ~off:0 ~len in
      Alcotest.(check string) "contents" raw "foo & bar" ;
      Gz.Inf.flush decoder
    | `Malformed err -> Alcotest.failf "Malformed GZip: %s" err in
  let () = match Gz.Inf.decode decoder with
    | `Flush _ -> Alcotest.failf "Unexpected `Flush signal"
    | `Await _ -> Alcotest.failf "Unexpected `Await signal"
    | `End decoder ->
      Alcotest.(check pass) "GZip terminate" () () ;
      Alcotest.(check (option string)) "filename" (Gz.Inf.filename decoder) (Some "foo.gz")
    | `Malformed err -> Alcotest.failf "Malformed GZip: %s" err in
  let ic = Gzip.open_in "foo.gz" in
  let rs = Bytes.create 0x1000 in
  let ln = Gzip.input ic rs 0 0x1000 in
  Alcotest.(check string) "contents" (Bytes.sub_string rs 0 ln) "foo & bar" ;
  Gzip.close_in ic
;;

let test_invalid_hcrc () =
  Alcotest.test_case "invalid header crc" `Quick @@ fun () ->
  let inputs =
    [ "\x1f\x8b\x08\x0a\x00\x00\x00\x00\x02\x03\x66\x6f\x6f\x2e\x67\x7a"
    ; "\x00"; "\x4b\xcb\x71\xde"; (* HCRC *) "\xcf\x57\x50\x53\x48\x4a\x2c\x02\x00\x8f\x47"
    ; "\xe4\xdd\x09\x00\x00\x00" ] in
  let decoder = Gz.Inf.decoder (`String (String.concat "" inputs)) ~o in
  match Gz.Inf.decode decoder with
  | `Malformed "Invalid GZip header checksum" ->
    Alcotest.(check pass) "invalid header checksum" () ()
  | `Malformed err -> Alcotest.failf "Malformed GZip: %s" err
  | `Flush _ | `Await _ | `End _ ->
    Alcotest.failf "Invalid signal (`Await | `Flush | `End)"

let os = Alcotest.testable Gz.pp_os Gz.equal_os

let test_gzip_os v_os =
  Alcotest.test_case (Fmt.strf "GZip with OS (%a)" Gz.pp_os v_os) `Quick @@ fun () ->
  let input = random 256 in
  let buf = Buffer.create 16 in
  let encoder = Gz.Def.encoder (`String input) (`Buffer buf) ~mtime:0l v_os ~hcrc:true ~q ~w ~level:0 in
  let rec go encoder = match Gz.Def.encode encoder with
    | `Await _ -> Alcotest.failf "Unexpected `Await signal"
    | `Flush _ -> Alcotest.failf "Unexpected `Flush signal"
    | `End _ -> Buffer.contents buf in
  let contents = go encoder in
  let decoder = Gz.Inf.decoder (`String contents) ~o in
  let decoder = match Gz.Inf.decode decoder with
    | `Await _ | `End _ -> Alcotest.failf "Unexpected `Await or `End signal"
    | `Flush decoder ->
      let len = bigstring_length o - Gz.Inf.dst_rem decoder in
      let raw = Bigstringaf.substring o ~off:0 ~len in
      Alcotest.(check string) "contents" raw input ;
      Gz.Inf.flush decoder
    | `Malformed err -> Alcotest.failf "Malformed GZip: %s" err in
  match Gz.Inf.decode decoder with
  | `Flush _ -> Alcotest.failf "Unexpected `Flush signal"
  | `Await _ -> Alcotest.failf "Unexpected `Await signal"
  | `End decoder ->
    Alcotest.(check pass) "GZip terminate" () () ;
    Alcotest.(check os) "os" v_os (Gz.Inf.os decoder)
  | `Malformed err -> Alcotest.failf "Malformed GZip: %s" err

let test_gzip_extra () =
  Alcotest.test_case "GZip with extra" `Quick @@ fun () ->
  let inputs =
    [ "\x1f\x8b\x08\x0c\x63\xcb\x5f\x5e\x00\x03"
    ; "\x00\x0a"
    ; "lx\x00\x06ubuntu"
    ; "\x66\x6f\x6f\x2e\x74\x78"
    ; "\x74\x00\x4b\xcb\xcf\xe7\x02\x00\xa8\x65\x32\x7e\x04\x00\x00\x00" ] in
  let decoder = Gz.Inf.decoder (`String (String.concat "" inputs)) ~o in
  let decoder = match Gz.Inf.decode decoder with
    | `Flush decoder ->
      let len = bigstring_length o - Gz.Inf.dst_rem decoder in
      let raw = Bigstringaf.substring o ~off:0 ~len in
      Alcotest.(check string) "contents" raw "foo\n" ;
      Gz.Inf.flush decoder
    | `Malformed err -> Alcotest.failf "Malformed GZip: %s" err
    | `Await _ | `End _ -> Alcotest.failf "Unexpected `Await or `End signal" in
  match Gz.Inf.decode decoder with
  | `Flush _ -> Alcotest.failf "Unexpected `Flush signal"
  | `Await _ -> Alcotest.failf "Unexpected `Await signal"
  | `End decoder ->
    Alcotest.(check pass) "GZip terminate" () () ;
    Alcotest.(check (option string)) "extra" (Gz.Inf.extra ~key:"lx" decoder) (Some "ubuntu")
  | `Malformed err -> Alcotest.failf "Malformed GZip: %s" err

let () =
  Alcotest.run "z"
    [ "invalids", [ invalid_complement_of_length ()
                  ; invalid_kind_of_block ()
                  ; invalid_code_lengths ()
                  ; invalid_bit_length_repeat ()
                  ; invalid_codes ()
                  ; invalid_lengths ()
                  ; invalid_distances ()
                  ; too_many_length_or_distance_symbols ()
                  ; invalid_distance_code ()
                  ; invalid_distance_too_far_back () ]
    ; "valids", [ fixed ()
                ; stored ()
                ; length_extra ()
                ; long_distance_and_extra ()
                ; window_end ()
                ; huffman_length_extra ()
                ; dynamic_and_fixed ()
                ; fixed_and_dynamic ()
                ; dynamic_and_dynamic ()
                ; flat_of_string ()
                ; flat_block ()
                ; flat ()
                ; max_flat ()
                ; fixed_and_flat ()
                ; flat_and_fixed () ]
    ; "fuzz", [ fuzz0 ()
              ; fuzz1 ()
              ; fuzz2 ()
              ; fuzz3 ()
              ; fuzz4 ()
              ; fuzz5 ()
              ; fuzz6 ()
              ; fuzz7 ()
              ; fuzz8 ()
              ; fuzz9 ()
              ; fuzz10 ()
              ; fuzz11 ()
              ; fuzz12 ()
              ; fuzz13 ()
              ; fuzz14 ()
              ; fuzz15 ()
              ; fuzz16 ()
              ; fuzz17 ()
              ; fuzz18 () ]
    ; "huffman", [ tree_0 ()
                 ; tree_rfc5322_corpus () ]
    ; "lz77", [ lz77_0 ()
              ; lz77_1 ()
              ; lz77_2 ()
              ; lz77_3 ()
              ; lz77_4 ()
              ; lz77_corpus_rfc5322 () ]
    ; "calgary", [ test_corpus "bib"
                 ; test_corpus "rfc5322.txt"
                 ; test_corpus "book1"
                 ; test_corpus "book2"
                 ; test_corpus "geo"
                 ; test_corpus "news"
                 ; test_corpus "obj1"
                 ; test_corpus "obj2"
                 ; test_corpus "paper1"
                 ; test_corpus "paper2"
                 ; test_corpus "pic"
                 ; test_corpus "progc"
                 ; test_corpus "progl"
                 ; test_corpus "progp"
                 ; test_corpus "trans" ]
    ; "zlib", [ test_empty_with_zlib ()
              ; test_empty_with_zlib_and_small_output ()
              ; test_empty_with_zlib_byte_per_byte ()
              ; test_corpus_with_zlib "bib"
              ; test_corpus_with_zlib "book1"
              ; test_corpus_with_zlib "book2"
              ; test_corpus_with_zlib "geo"
              ; test_corpus_with_zlib "news"
              ; test_corpus_with_zlib "obj1"
              ; test_corpus_with_zlib "obj2"
              ; test_corpus_with_zlib "paper1"
              ; test_corpus_with_zlib "paper2"
              ; test_corpus_with_zlib "pic"
              ; test_corpus_with_zlib "progc"
              ; test_corpus_with_zlib "progl"
              ; test_corpus_with_zlib "progp"
              ; test_corpus_with_zlib "trans"
              ; test_multiple_flush_zlib () ]
    ; "gzip", [ test_empty_gzip ()
              ; test_empty_gzip_with_name ()
              ; test_foo_gzip ()
              ; test_multiple_flush_gzip ()
              ; test_generate_empty_gzip ()
              ; test_generate_empty_gzip_with_name ()
              ; test_generate_foo_gzip ()
              ; test_corpus_with_gzip "bib"
              ; test_corpus_with_gzip "book1"
              ; test_corpus_with_gzip "book2"
              ; test_corpus_with_gzip "geo"
              ; test_corpus_with_gzip "news"
              ; test_corpus_with_gzip "obj1"
              ; test_corpus_with_gzip "obj2"
              ; test_corpus_with_gzip "paper1"
              ; test_corpus_with_gzip "paper2"
              ; test_corpus_with_gzip "pic"
              ; test_corpus_with_gzip "progc"
              ; test_corpus_with_gzip "progl"
              ; test_corpus_with_gzip "progp"
              ; test_corpus_with_gzip "trans"
              ; test_with_camlzip ()
              ; test_gzip_hcrc ()
              ; test_invalid_hcrc ()
              ; test_gzip_extra () ]
    ; "gzip with os", [ test_gzip_os Gz.FAT
                      ; test_gzip_os Gz.Amiga
                      ; test_gzip_os Gz.VMS
                      ; test_gzip_os Gz.Unix
                      ; test_gzip_os Gz.VM
                      ; test_gzip_os Gz.Atari
                      ; test_gzip_os Gz.HPFS
                      ; test_gzip_os Gz.Macintosh
                      ; test_gzip_os Gz.Z
                      ; test_gzip_os Gz.CPM
                      ; test_gzip_os Gz.TOPS20
                      ; test_gzip_os Gz.NTFS
                      ; test_gzip_os Gz.QDOS
                      ; test_gzip_os Gz.Acorn
                      ; test_gzip_os Gz.Unknown ]
    ; "hang", [ hang0 () ]
    ; "git", [ git_object () ]
    ; "higher", [ higher_zlib0 ()
                ; higher_zlib1 ()
                ; higher_zlib2 ()
                ; higher_zlib3 () ] ]
