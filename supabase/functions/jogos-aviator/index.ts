import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
const HEADERS={"Content-Type":"application/json; charset=utf-8","Cache-Control":"no-store"};
Deno.serve(async(req:Request)=>{
 if(req.method!=="POST") return new Response(JSON.stringify({error:"METHOD_NOT_ALLOWED"}),{status:405,headers:HEADERS});
 const secret=Deno.env.get("AVIATOR_ENGINE_SECRET")||"";
 if(!secret||req.headers.get("x-aviator-secret")!==secret) return new Response(JSON.stringify({error:"UNAUTHORIZED"}),{status:401,headers:HEADERS});
 const url=Deno.env.get("SUPABASE_URL")!, key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
 const sb=createClient(url,key,{auth:{persistSession:false}});
 const {data,error}=await sb.rpc("jl_aviator_engine_tick");
 if(error) return new Response(JSON.stringify({error:error.message}),{status:500,headers:HEADERS});
 await sb.rpc("jl_aviator_open_next_if_due");
 return new Response(JSON.stringify(data),{status:200,headers:HEADERS});
});