precision highp float;
precision highp int;
precision highp sampler2D;

#include <pathtracing_uniforms_and_defines>

#define N_SPHERES 2
#define N_QUADS 9


//-----------------------------------------------------------------------

vec3 rayOrigin, rayDirection;

struct Sphere { float radius; vec3 position; vec3 emission; vec3 color; int type; };
struct Quad { vec3 normal; vec3 v0; vec3 v1; vec3 v2; vec3 v3; vec3 emission; vec3 color; int type; };

Sphere spheres[N_SPHERES];
Quad quads[N_QUADS];


#include <pathtracing_random_functions>

#include <pathtracing_calc_fresnel_reflectance>

#include <pathtracing_sphere_intersect>

#include <pathtracing_quad_intersect>


vec3 randPointOnLight; // global variable that can be used across multiple functions

vec3 sampleQuadLight(vec3 x, vec3 nl, Quad light, out float weight)
{
	// vec3 randPointOnLight is already chosen on each bounces loop iteration below in the CalculateRadiance() function 
	
	vec3 dirToLight = randPointOnLight - x;
	float r2 = distance(light.v0, light.v1) * distance(light.v0, light.v3);
	float d2 = dot(dirToLight, dirToLight);
	float cos_a_max = sqrt(1.0 - clamp( r2 / d2, 0.0, 1.0));
	dirToLight = normalize(dirToLight);
	float dotNlRayDir = max(0.0, dot(nl, dirToLight)); 
	weight =  2.0 * (1.0 - cos_a_max) * max(0.0, -dot(dirToLight, light.normal)) * dotNlRayDir; 
	weight = clamp(weight, 0.0, 1.0);
	return dirToLight;
}



//------------------------------------------------------------------------------------------------------------------------------------------------------------
float SceneIntersect( vec3 rOrigin, vec3 rDirection, out vec3 hitNormal, out vec3 hitEmission, out vec3 hitColor, out float hitObjectID, out int hitType )
//------------------------------------------------------------------------------------------------------------------------------------------------------------
{
	float d;
	float t = INFINITY;
	int objectCount = 0;
	
	hitObjectID = -INFINITY;

	
	for (int i = 0; i < N_SPHERES; i++)
	{
		d = SphereIntersect( spheres[i].radius, spheres[i].position, rOrigin, rDirection );
		if (d < t)
		{
			t = d;
			hitNormal = (rOrigin + rDirection * t) - spheres[i].position;
			hitEmission = spheres[i].emission;
			hitColor = spheres[i].color;
			hitType = spheres[i].type;
			hitObjectID = float(objectCount);
		}
		objectCount++;
	}
	
	for (int i = 0; i < N_QUADS; i++)
	{
		d = QuadIntersect( quads[i].v0, quads[i].v1, quads[i].v2, quads[i].v3, rOrigin, rDirection, true );
		if (d < t)
		{
			t = d;
			hitNormal = quads[i].normal;
			hitEmission = quads[i].emission;
			hitColor = quads[i].color;
			hitType = quads[i].type;
			hitObjectID = float(objectCount);
		}
		objectCount++;
	}
	
	return t;
} // end float SceneIntersect( vec3 rOrigin, vec3 rDirection, out vec3 hitNormal, out vec3 hitEmission, out vec3 hitColor, out float hitObjectID, out int hitType )


/* Credit: Some of the equi-angular sampling code is borrowed from https://www.shadertoy.com/view/Xdf3zB posted by user 'sjb' ,
// who in turn got it from the paper 'Importance Sampling Techniques for Path Tracing in Participating Media' ,
which can be viewed at: https://docs.google.com/viewer?url=https%3A%2F%2Fwww.solidangle.com%2Fresearch%2Fegsr2012_volume.pdf */
void sampleEquiAngular( float u, float maxDistance, vec3 rOrigin, vec3 rDirection, vec3 lightPos, out float dist, out float pdf )
{
	// get coord of closest point to light along (infinite) ray
	float delta = dot(lightPos - rOrigin, rDirection);
	
	// get distance this point is from light
	float D = distance(rOrigin + delta * rDirection, lightPos);

	// get angle of endpoints
	float thetaA = atan(0.0 - delta, D);
	float thetaB = atan(maxDistance - delta, D);

	// take sample
	float t = D * tan( mix(thetaA, thetaB, u) );
	dist = delta + t;
	pdf = D / ( (thetaB - thetaA) * (D * D + t * t) );
}


#define FOG_COLOR vec3(0.05, 0.05, 0.4) // color of the fog / participating medium
#define FOG_DENSITY 0.005 // this is dependent on the particular scene size dimensions


//-----------------------------------------------------------------------------------------------------------------------------
vec3 CalculateRadiance( out vec3 objectNormal, out vec3 objectColor, out float objectID, out float pixelSharpness )
//-----------------------------------------------------------------------------------------------------------------------------
{
	Quad chosenLight;

	vec3 cameraRayOrigin = rayOrigin;
	vec3 cameraRayDirection = rayDirection;
	vec3 vRayOrigin, vRayDirection;

	// recorded intersection data (from eye):
	vec3 eHitNormal, eHitEmission, eHitColor;
	float eHitObjectID;
	int eHitType = -100; // note: make sure to initialize this to a nonsense type id number!
	// recorded intersection data (from volumetric particle):
	vec3 vHitNormal, vHitEmission, vHitColor;
	float vHitObjectID;
	int vHitType = -100; // note: make sure to initialize this to a nonsense type id number!

	vec3 accumCol = vec3(0.0);
	vec3 mask = vec3(1.0);
	vec3 dirToLight;
	vec3 lightVec;
	vec3 particlePos;
	vec3 tdir;
	vec3 x, n, nl;
	
	float nc, nt, ratioIoR, Re, Tr;
	float P, RP, TP;
	float weight;
	float t, vt, camt;
	float xx;
	float pdf;
	float d;
	float geomTerm;
	float trans;

	int diffuseCount = 0;
	int previousIntersecType = -100;
	
	bool rayWasRefracted = false;
	bool bounceIsSpecular = true;
	bool sampleLight = false;

	
	
	
	// depth of 4 is required for higher quality glass refraction
	for (int bounces = 0; bounces < 4; bounces++)
	{
		chosenLight = quads[0];
		randPointOnLight.x = chosenLight.v0.x;
		randPointOnLight.y = mix(chosenLight.v0.y, chosenLight.v2.y, clamp(rng(), 0.1, 0.9));
		randPointOnLight.z = mix(chosenLight.v0.z, chosenLight.v2.z, clamp(rng(), 0.1, 0.9));

		float u = rng();
		
		t = SceneIntersect(rayOrigin, rayDirection, eHitNormal, eHitEmission, eHitColor, eHitObjectID, eHitType);
		
		// on first loop iteration, save intersection distance along camera ray (t) into camt variable for use below
		if (bounces == 0)
		{
			camt = t;
		}
			
		// sample along intial ray from camera into the scene
		sampleEquiAngular(u, camt, cameraRayOrigin, cameraRayDirection, randPointOnLight, xx, pdf);

		// create a particle along cameraRay and cast a shadow ray towards light (similar to Direct Lighting)
		particlePos = cameraRayOrigin + xx * cameraRayDirection;
		lightVec = randPointOnLight - particlePos;
		d = length(lightVec);

		vRayOrigin = particlePos;
		vRayDirection = normalize(lightVec);

		vt = SceneIntersect(vRayOrigin, vRayDirection, vHitNormal, vHitEmission, vHitColor, vHitObjectID, vHitType);
		
		// if the particle can see the light source, apply volumetric lighting calculation
		if (vHitType == LIGHT)
		{	
			trans = exp( -((d + xx) * FOG_DENSITY) );
			geomTerm = 1.0 / (d * d);
			
			accumCol += FOG_COLOR * vHitEmission * geomTerm * trans / pdf;
		}
		// otherwise the particle will remain in shadow - this is what produces the shafts of light vs. the volume shadows


		// useful data 
		n = normalize(eHitNormal);
		nl = dot(n, rayDirection) < 0.0 ? n : -n;
		x = rayOrigin + rayDirection * t;

		if (bounces == 0)
		{
			//objectNormal = nl;
			objectColor = eHitColor;
			objectID = eHitObjectID;
		}
		if (diffuseCount == 0) // handles reflections of light sources
		{
			objectNormal = nl; 
		}

		// now do the normal path tracing routine with the camera ray
		if (eHitType == LIGHT)
		{
			if (bounceIsSpecular || sampleLight)
			{
				trans = exp( -((d + camt) * FOG_DENSITY) );
				accumCol += mask * eHitEmission * trans;	
			}

			// normally we would 'break' here, but 'continue' allows more particles to be lit
			continue;
			//break;
		}
		
		if (sampleLight)
			break;
		
		
		if (eHitType == DIFF) // Ideal DIFFUSE reflection
		{
			diffuseCount++;

			mask *= eHitColor;

			bounceIsSpecular = false;

			if (diffuseCount == 1 && rand() < 0.5)
			{
				mask *= 2.0;
				// choose random Diffuse sample vector
				rayDirection = randomCosWeightedDirectionInHemisphere(nl);
				rayOrigin = x + nl * uEPS_intersect;
				continue;
			}
			
			if (rng() < 0.5)
			{
				chosenLight = quads[8];
				randPointOnLight.x = mix(chosenLight.v0.x, chosenLight.v2.x, clamp(rng(), 0.1, 0.9));
				randPointOnLight.y = chosenLight.v0.y;
				randPointOnLight.z = mix(chosenLight.v0.z, chosenLight.v2.z, clamp(rng(), 0.1, 0.9));
			}
			dirToLight = sampleQuadLight(x, nl, chosenLight, weight);
			mask *= diffuseCount == 1 ? 2.0 : 1.0;
			mask *= weight;
			mask *= 2.0;

			rayDirection = dirToLight;
			rayOrigin = x + nl * uEPS_intersect;
			
			sampleLight = true;
			continue;	
		}
		
		if (eHitType == SPEC)  // Ideal SPECULAR reflection
		{
			mask *= eHitColor;

			rayDirection = reflect(rayDirection, nl);
			rayOrigin = x + nl * uEPS_intersect;
			
			//bounceIsSpecular = true; // turn on mirror caustics
			
			continue;
		}

		if (eHitType == REFR)  // Ideal dielectric REFRACTION
		{
			previousIntersecType = REFR;

			nc = 1.0; // IOR of Air
			nt = 1.5; // IOR of common Glass
			Re = calcFresnelReflectance(rayDirection, n, nc, nt, ratioIoR);
			Tr = 1.0 - Re;
			P  = 0.25 + (0.5 * Re);
			RP = Re / P;
			TP = Tr / (1.0 - P);

			if (bounces == 0 && rand() < P)
			{
				mask *= RP;
				rayDirection = reflect(rayDirection, nl); // reflect ray from surface
				rayOrigin = x + nl * uEPS_intersect;
				    
				//bounceIsSpecular = true; // turn on reflecting caustics
			    	continue;	
			}
			// transmit ray through surface
			
			mask *= TP;
			mask *= eHitColor;

			tdir = refract(rayDirection, nl, ratioIoR);
			rayDirection = tdir;
			rayOrigin = x - nl * uEPS_intersect;

			//bounceIsSpecular = true; // turn on refracting caustics
			continue;
			
		} // end if (eHitType == REFR)
		
		if (eHitType == COAT)  // Diffuse object underneath with ClearCoat on top
		{
			nc = 1.0; // IOR of air
			nt = 1.4; // IOR of ClearCoat 
			Re = calcFresnelReflectance(rayDirection, nl, nc, nt, ratioIoR);
			Tr = 1.0 - Re;
			P  = 0.25 + (0.5 * Re);
			RP = Re / P;
			TP = Tr / (1.0 - P);
			
			// choose either specular reflection or diffuse
			if (diffuseCount == 0 && rand() < P)
			{	
				mask *= RP;
				rayDirection = reflect(rayDirection, nl); // reflect ray from surface
				rayOrigin = x + nl * uEPS_intersect;
				continue;	
			}

			diffuseCount++;

			bounceIsSpecular = false;

			mask *= TP;
			mask *= eHitColor;

			if (diffuseCount == 1 && rand() < 0.5)
			{
				mask *= 2.0;
				// choose random Diffuse sample vector
				rayDirection = randomCosWeightedDirectionInHemisphere(nl);
				rayOrigin = x + nl * uEPS_intersect;
				continue;
			}
			
			if (rng() < 0.5)
			{
				chosenLight = quads[8];
				randPointOnLight.x = mix(chosenLight.v0.x, chosenLight.v2.x, clamp(rng(), 0.1, 0.9));
				randPointOnLight.y = chosenLight.v0.y;
				randPointOnLight.z = mix(chosenLight.v0.z, chosenLight.v2.z, clamp(rng(), 0.1, 0.9));
			}
			dirToLight = sampleQuadLight(x, nl, chosenLight, weight);
			mask *= diffuseCount == 1 ? 2.0 : 1.0;
			mask *= weight;
			mask *= 2.0;

			rayDirection = dirToLight;
			rayOrigin = x + nl * uEPS_intersect;
			
			sampleLight = true;
			continue;
			
		} //end if (eHitType == COAT)
		
	} // end for (int bounces = 0; bounces < 4; bounces++)


	return max(vec3(0), accumCol);

} // end vec3 CalculateRadiance( out vec3 objectNormal, out vec3 objectColor, out float objectID, out float pixelSharpness )

//-----------------------------------------------------------------------
void SetupScene(void)
//-----------------------------------------------------------------------
{
	vec3 z  = vec3(0);// No color value, Black        
	vec3 L1 = vec3(1.0, 1.0, 1.0) * 20.0;
	
	spheres[0] = Sphere(  10.0, vec3(0, -40, -40), z, vec3(1.0, 1.0, 1.0),  DIFF);// Diffuse Sphere Left
	spheres[1] = Sphere(  10.0, vec3(30, -40, -40), z, vec3(1.0, 1.0, 0.0),  COAT);// ClearCoat Sphere Right
	
	quads[0] = Quad( vec3(-1, 0, 0), vec3(80, -2,-2), vec3(80, -2, 2), vec3(80, 2, 2), vec3(80, 2, -2), L1, z, LIGHT);// Rectangular Area Light

	quads[1] = Quad( vec3( 0, 0, 1), vec3(-50, -50,-50), vec3(50, -50,-50), vec3(50, 50,-50), vec3(-50, 50,-50), z, vec3( 1.0,  1.0,  1.0), DIFF);// Back Wall
	quads[2] = Quad( vec3( 1, 0, 0), vec3(-50, -50, 50), vec3( -50, -50,-50), vec3( -50, 50,-50), vec3( -50, 50, 50), z, vec3( 0.7, 0.05, 0.05), DIFF);// Left Wall Red
	quads[3] = Quad( vec3(-1, 0, 0), vec3(50, -50,-50), vec3(50, -50, 50), vec3(50, -2, 50), vec3(50, -2, -50), z, vec3(0.05, 0.05, 0.7 ), DIFF);// Right Wall Blue
	quads[4] = Quad( vec3(-1, 0, 0), vec3(50, 2,-50), vec3(50, 2, 50), vec3(50, 50, 50), vec3(50, 50, -50), z, vec3(0.05, 0.05, 0.7 ), DIFF);// Right Wall Blue
	quads[5] = Quad( vec3(-1, 0, 0), vec3(50, -50,-50), vec3(50, -50, -2), vec3(50, 50, -2), vec3(50, 50, -50), z, vec3(0.05, 0.05, 0.7 ), DIFF);// Right Wall Blue
	quads[6] = Quad( vec3(-1, 0, 0), vec3(50, -50, 2), vec3(50, -50, 50), vec3(50, 50, 50), vec3(50, 50, 2), z, vec3(0.05, 0.05, 0.7 ), DIFF);// Right Wall Blue
	quads[7] = Quad( vec3( 0, 1, 0), vec3(-50, -50, 50), vec3(50, -50, 50), vec3(50, -50, -50), vec3( -50, -50, -50), z, vec3( 1.0,  1.0,  1.0), DIFF);// Floor
	
	quads[8] = Quad( vec3( 0,-1, 0), vec3(-5, 20, -40), vec3(5, 20, -40), vec3(5, 20, -35), vec3(-5, 20, -35), vec3(0.5), z, LIGHT);// Ceiling
}


#include <pathtracing_main>