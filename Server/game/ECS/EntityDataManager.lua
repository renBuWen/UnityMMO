EntityDataManager = BaseClass()
ECS.EntityDataManager = EntityDataManager

local EntityData = {
	Version=0, 
	Archetype = nil,
	Chunk = nil,
	IndexInChunk = 0
}
function EntityDataManager:Constructor( capacity )
	self.m_Entities = {}
	self.m_EntitiesCapacity = capacity
	self.m_EntitiesFreeIndex = 0
    self.GlobalSystemVersion = ECS.ChangeVersionUtility.InitialGlobalSystemVersion

	self:InitializeAdditionalCapacity(1)
	-- const int componentTypeOrderVersionSize = sizeof(int) * TypeManager.MaximumTypesCount;
 --    m_ComponentTypeOrderVersion = (int*) UnsafeUtility.Malloc(componentTypeOrderVersionSize,
 --        UnsafeUtility.AlignOf<int>(), Allocator.Persistent);
 --    UnsafeUtility.MemClear(m_ComponentTypeOrderVersion, componentTypeOrderVersionSize);
end

function EntityDataManager:InitializeAdditionalCapacity( start )
	for i=start,self.m_EntitiesCapacity do
		self.m_Entities[i] = {}
		self.m_Entities[i].IndexInChunk = i
        self.m_Entities[i].Version = 1
        self.m_Entities[i].Chunk = nil
        self.m_Entities[i].Archetype = nil
	end
    --Last entity indexInChunk identifies that we ran out of space...
    self.m_Entities[self.m_EntitiesCapacity].IndexInChunk = -1;
end

function EntityDataManager:HasComponent( entity, com_type_name )
	if not self:Exit(entity) then 
		return false
	end
	local archetype = self.m_Entities[entity.Index].Archetype
    return ChunkDataUtility.GetIndexInTypeArray(archetype, type.TypeIndex) ~= -1;
end

function EntityDataManager:GetComponentDataWithTypeRO( entity, typeIndex )
	local entityData = self.m_Entities[entity.Index]
    return ChunkDataUtility.GetComponentDataWithTypeRO(entityData.Chunk, entityData.IndexInChunk, typeIndex)
end

function EntityDataManager:CreateEntities( archetypeManager, archetype, entities, count )
    -- local sharedComponentDataIndices = stackalloc int[archetype.NumSharedComponents]
    -- UnsafeUtility.MemClear(sharedComponentDataIndices, archetype.NumSharedComponents*sizeof(int))
    while count ~= 0 do
        local chunk = archetypeManager:GetChunkWithEmptySlots(archetype, sharedComponentDataIndices)
        local allocatedIndex
        local allocatedCount, allocatedIndex = archetypeManager:AllocateIntoChunk(chunk, count)
        self:AllocateEntities(archetype, chunk, allocatedIndex, allocatedCount, entities)
        ChunkDataUtility.InitializeComponents(chunk, allocatedIndex, allocatedCount)

        entities = entities + allocatedCount
        count = count - allocatedCount
    end
    self:IncrementComponentTypeOrderVersion(archetype)
end

function EntityDataManager:IncrementComponentTypeOrderVersion( archetype )
	for t=1,archetype.TypesCount do
		local typeIndex = archetype.Types[t].TypeIndex
        self.m_ComponentTypeOrderVersion[typeIndex] = self.m_ComponentTypeOrderVersion[typeIndex] + 1
	end
end

function EntityDataManager:GetComponentTypeOrderVersion( typeIndex )
    return m_ComponentTypeOrderVersion[typeIndex]
end

function EntityDataManager:AddComponent( entity, com_type, archetypeManager, sharedComponentDataManager, groupManager, componentTypeInArchetypeArray )
    local componentType = ECS.ComponentTypeInArchetype.New(type)
	local archetype = self:GetArchetype(entity)

    local t = 1
    componentTypeInArchetypeArray = {}--Cat_Todo : obj pool optimize
    while (t <= archetype.TypesCount and archetype.Types[t] < componentType) do
        componentTypeInArchetypeArray[t] = archetype.Types[t]
        t = t + 1
    end
    --按顺序把新的类型插入临时列表里
    componentTypeInArchetypeArray[t] = componentType
    while (t <= archetype.TypesCount) do
        componentTypeInArchetypeArray[t + 1] = archetype.Types[t]
        t = t + 1
    end

    local newType = archetypeManager:GetOrCreateArchetype(componentTypeInArchetypeArray,
        archetype.TypesCount + 1, groupManager)

    local sharedComponentDataIndices = nil
    if newType.NumSharedComponents > 0 then
        local oldSharedComponentDataIndices = self:GetComponentChunk(entity).SharedComponentValueArray
        if type.IsSharedComponent then
            -- local stackAlloced = stackalloc int[newType.NumSharedComponents]
            sharedComponentDataIndices = stackAlloced

            if archetype.SharedComponentOffset == nil then
                sharedComponentDataIndices[1] = 0
            else
                t = 1
                local sharedIndex = 1
                while t <= archetype.TypesCount and archetype.Types[t] < componentType do
                    if archetype.SharedComponentOffset[t] ~= -1 then
                        sharedComponentDataIndices[sharedIndex] = oldSharedComponentDataIndices[sharedIndex]
                        sharedIndex = sharedIndex + 1
                    end
                    t = t + 1
                end

                sharedComponentDataIndices[sharedIndex] = 0
                while (t <= archetype.TypesCount) do
                    if (archetype.SharedComponentOffset[t] ~= -1) then
                        sharedComponentDataIndices[sharedIndex + 1] =
                            oldSharedComponentDataIndices[sharedIndex]
                        sharedIndex = sharedIndex + 1
                    end
                    t = t + 1
                end
            end
        else
            -- reuse old sharedComponentDataIndices
            sharedComponentDataIndices = oldSharedComponentDataIndices
        end
    end

    self:SetArchetype(archetypeManager, entity, newType, sharedComponentDataIndices)
    self:IncrementComponentOrderVersion(newType, self:GetComponentChunk(entity), sharedComponentDataManager)
end

function EntityDataManager:TryRemoveEntityId( entities, count, archetypeManager, sharedComponentDataManager, groupManager, componentTypeInArchetypeArray )
    local entityIndex = 0;
    while (entityIndex ~= count) do
        local indexInChunk
        local batchCount
        local manager = self
        local chunk = EntityChunkBatch(manager, entities + entityIndex, count - entityIndex, indexInChunk,
            batchCount);
        local archetype = GetArchetype(entities[entityIndex]);
        if (not archetype.SystemStateCleanupNeeded) then
            DeallocateDataEntitiesInChunk(manager, entities + entityIndex, chunk, indexInChunk, batchCount);
            IncrementComponentOrderVersion(chunk.Archetype, chunk, sharedComponentDataManager);

            if (chunk.ManagedArrayIndex >= 0) then
                -- We can just chop-off the end, no need to copy anything
                if (chunk.Count ~= indexInChunk + batchCount) then
                    ChunkDataUtility.CopyManagedObjects(archetypeManager, chunk, chunk.Count - batchCount,
                        chunk,
                        indexInChunk, batchCount)
                end

                ChunkDataUtility.ClearManagedObjects(archetypeManager, chunk, chunk.Count - batchCount,
                    batchCount)
            end

            chunk.Archetype.EntityCount = chunk.Archetype.EntityCount - batchCount
            archetypeManager.SetChunkCount(chunk, chunk.Count - batchCount)
        else
            for batchEntityIndex=1,batchCount do
                local entity = entities[entityIndex + batchEntityIndex]
                local removedTypes = 0
                local removedComponentIsShared = false
                for t=2,archetype.TypesCount do
                    local type = archetype.Types[t]
                    
                    if (not (type.IsSystemStateComponent or type.IsSystemStateSharedComponent)) then
                        removedTypes = removedTypes + 1
                        -- removedComponentIsShared |= type.IsSharedComponent
                    else
                        componentTypeInArchetypeArray[t - removedTypes] = archetype.Types[t]
                    end
                end

                componentTypeInArchetypeArray[archetype.TypesCount - removedTypes] =
                    new ComponentTypeInArchetype(ComponentType.Create("CleanupEntity"))

                local newType = archetypeManager.GetOrCreateArchetype(componentTypeInArchetypeArray,
                    archetype.TypesCount - removedTypes + 1, groupManager)

                local sharedComponentDataIndices = nil
                if (newType.NumSharedComponents > 0) then
                    local oldSharedComponentDataIndices =
                        GetComponentChunk(entity).SharedComponentValueArray
                    if (removedComponentIsShared) then
                        local tempAlloc = {}
                        sharedComponentDataIndices = tempAlloc

                        local srcIndex = 0
                        local dstIndex = 0
                        for t=1,archetype.TypesCount do
                            if (archetype.SharedComponentOffset[t] ~= -1) then
                                local typeIndex = archetype.Types[t].TypeIndex
                                local systemStateType = typeof(ISystemStateComponentData).IsAssignableFrom(TypeManager.GetType(typeIndex))
                                local systemStateSharedType = typeof(ISystemStateSharedComponentData).IsAssignableFrom(TypeManager.GetType(typeIndex))
                                if (not (systemStateType or systemStateSharedType)) then
                                    srcIndex = srcIndex + 1
                                else
                                    sharedComponentDataIndices[dstIndex] =
                                        oldSharedComponentDataIndices[srcIndex]
                                    srcIndex = srcIndex + 1
                                    dstIndex = dstIndex + 1
                                end
                            end
                        end
                    else
                        -- reuse old sharedComponentDataIndices
                        sharedComponentDataIndices = oldSharedComponentDataIndices;
                    end
                end
                self:IncrementComponentOrderVersion(archetype, GetComponentChunk(entity),
                    sharedComponentDataManager);
                self:SetArchetype(archetypeManager, entity, newType, sharedComponentDataIndices);
            end
        end
    end
    entityIndex = entityIndex + batchCount
end

function EntityDataManager:SetArchetype( typeMan, entity, archetype, sharedComponentDataIndices )
    local chunk = typeMan:GetChunkWithEmptySlots(archetype, sharedComponentDataIndices)
    local allocatedCount, chunkIndex = typeMan:AllocateIntoChunk(chunk)

    local oldArchetype = self.m_Entities.Archetype[entity.Index]
    local oldChunk = self.m_Entities.ChunkData[entity.Index].Chunk
    local oldChunkIndex = self.m_Entities.ChunkData[entity.Index].IndexInChunk
    ChunkDataUtility.Convert(oldChunk, oldChunkIndex, chunk, chunkIndex)
    if chunk.ManagedArrayIndex >= 0 and oldChunk.ManagedArrayIndex >= 0 then
        ChunkDataUtility.CopyManagedObjects(typeMan, oldChunk, oldChunkIndex, chunk, chunkIndex, 1)
    end

    self.m_Entities.Archetype[entity.Index] = archetype
    self.m_Entities.ChunkData[entity.Index].Chunk = chunk
    self.m_Entities.ChunkData[entity.Index].IndexInChunk = chunkIndex

    local lastIndex = oldChunk.Count - 1
    if (lastIndex ~= oldChunkIndex) then
        local lastEntity = ChunkDataUtility.GetComponentDataRO(oldChunk, lastIndex, 0)
        self.m_Entities.ChunkData[lastEntity.Index].IndexInChunk = oldChunkIndex

        ChunkDataUtility.Copy(oldChunk, lastIndex, oldChunk, oldChunkIndex, 1)
        if (oldChunk.ManagedArrayIndex >= 0) then
            ChunkDataUtility.CopyManagedObjects(typeMan, oldChunk, lastIndex, oldChunk, oldChunkIndex, 1)
        end
    end

    if (oldChunk.ManagedArrayIndex >= 0) then
        ChunkDataUtility.ClearManagedObjects(typeMan, oldChunk, lastIndex, 1)
    end
    --Entity归新的Archetype了，所以旧的EnityCount要减1
    oldArchetype.EntityCount = oldArchetype.EntityCount - 1
    typeMan:SetChunkCount(oldChunk, lastIndex)
end

function EntityDataManager:AllocateEntities( arch, chunk, baseIndex, count, outputEntities )
    -- Assert.AreEqual(chunk.Archetype.Offsets[0], 0);
    -- Assert.AreEqual(chunk.Archetype.SizeOfs[0], sizeof(Entity));
    local entityInChunkStart = chunk.Buffer + baseIndex

    for var=1,count do
        local entityIndexInChunk = self.m_Entities.ChunkData[self.m_EntitiesFreeIndex].IndexInChunk
        if entityIndexInChunk == -1 then
            self:IncreaseCapacity()
            entityIndexInChunk = self.m_Entities.ChunkData[self.m_EntitiesFreeIndex].IndexInChunk
        end
        
        local entityVersion = self.m_Entities.Version[self.m_EntitiesFreeIndex]

        outputEntities[i].Index = self.m_EntitiesFreeIndex
        outputEntities[i].Version = entityVersion

        local entityInChunk = entityInChunkStart + i

        entityInChunk.Index = self.m_EntitiesFreeIndex
        entityInChunk.Version = entityVersion

        self.m_Entities.ChunkData[self.m_EntitiesFreeIndex].IndexInChunk = baseIndex + i
        self.m_Entities.Archetype[self.m_EntitiesFreeIndex] = arch
        self.m_Entities.ChunkData[self.m_EntitiesFreeIndex].Chunk = chunk
        
        self.m_EntitiesFreeIndex = entityIndexInChunk
    end
end

function EntityDataManager:IncreaseCapacity(  )
    self:SetCapacity(self.Capacity*2)
end

function EntityDataManager:GetCapacity( )
    return self.Capacity
end

function EntityDataManager:SetCapacity( value )
    if value <= self.m_EntitiesCapacity then
        return
    end

    local newEntities = self:CreateEntityData(value)
    self:CopyEntityData(newEntities, self.m_Entities, self.m_EntitiesCapacity)
    FreeEntityData(self.m_Entities)
    
    local startNdx = self.m_EntitiesCapacity - 1
    self.m_Entities = newEntities
    self.m_EntitiesCapacity = value

    self:InitializeAdditionalCapacity(startNdx)
    self.Capacity = value
end

function EntityDataManager:CreateEntityData( newCapacity )
    local entities = {}
    entities.Version   = {}
    entities.Archetype = {}
    entities.ChunkData = {}
    return entities
end